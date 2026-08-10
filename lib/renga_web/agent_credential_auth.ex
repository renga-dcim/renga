defmodule RengaWeb.AgentCredentialAuth do
  @moduledoc "Verifies key-bound agent requests and consumes runtime nonces."

  import Ecto.Query
  import Phoenix.Controller
  import Plug.Conn

  alias Renga.Accounts
  alias Renga.Accounts.Organization
  alias Renga.Enrollment.{AgentCredential, Canonical, EnrollmentReplay}
  alias Renga.Inventory.{Agent, Source}
  alias Renga.Repo
  alias RengaWeb.BodyDigestReader

  @skew_seconds 60

  def init(opts), do: opts

  def call(conn, _opts) do
    with {:ok, values} <- signed_values(conn),
         %AgentCredential{} = credential <- credential_for(values.credential_id),
         true <- verify(credential.public_key, values.signature, transcript(values)),
         {:ok, {organization, source, agent, credential}} <- authenticate(values, credential) do
      conn
      |> assign(:current_scope, Accounts.scope_for(organization))
      |> assign(:current_source, source)
      |> assign(:current_agent, agent)
      |> assign(:current_agent_credential, credential)
      |> assign(:current_installation_id, values.installation_id)
      |> assign(:agent_auth_kind, :credential)
    else
      _ -> unauthorized(conn)
    end
  end

  @doc "Builds the canonical, versioned runtime request transcript."
  def transcript(values) do
    Canonical.encode(%{
      "domain" => "renga/agent-credential/request",
      "version" => 1,
      "credential_id" => values.credential_id_encoded,
      "installation_id" => values.installation_id,
      "method" => String.upcase(values.method),
      "request_target" => values.request_target,
      "content_type" => values.content_type,
      "timestamp" => values.timestamp,
      "nonce" => values.nonce_encoded,
      "body_sha256" => Base.url_encode64(values.body_digest, padding: false)
    })
  end

  defp signed_values(conn) do
    now = DateTime.to_unix(Renga.Time.utc_now_ms())

    with {:ok, authorization} <- one_header(conn, "authorization"),
         "RengaKey " <> encoded_id <- authorization,
         {:ok, credential_id} <- decode_min(encoded_id, 32),
         {:ok, installation} <- one_header(conn, "x-renga-installation-id"),
         true <- byte_size(installation) == 36,
         {:ok, installation_id} <- Ecto.UUID.cast(installation),
         {:ok, timestamp_value} <- one_header(conn, "x-renga-timestamp"),
         {timestamp, ""} <- Integer.parse(timestamp_value),
         true <- Integer.to_string(timestamp) == timestamp_value,
         true <- abs(now - timestamp) <= @skew_seconds,
         {:ok, nonce_encoded} <- one_header(conn, "x-renga-nonce"),
         {:ok, nonce} <- decode_exact(nonce_encoded, 32),
         {:ok, signature_encoded} <- one_header(conn, "x-renga-signature"),
         {:ok, signature} <- decode_exact(signature_encoded, 64),
         {:ok, content_type} <- one_header(conn, "content-type"),
         {:ok, normalized_content_type} <- normalize_content_type(content_type),
         {:ok, body_digest} <- BodyDigestReader.fetch_digest(conn) do
      target =
        if conn.query_string == "",
          do: conn.request_path,
          else: conn.request_path <> "?" <> conn.query_string

      {:ok,
       %{
         credential_id: credential_id,
         credential_id_encoded: encoded_id,
         installation_id: installation_id,
         timestamp: timestamp,
         nonce: nonce,
         nonce_encoded: nonce_encoded,
         signature: signature,
         content_type: normalized_content_type,
         method: conn.method,
         request_target: target,
         body_digest: body_digest
       }}
    else
      _ -> :error
    end
  end

  defp normalize_content_type(value) do
    if String.valid?(value) do
      case value |> String.split(";") |> Enum.map(&String.trim/1) do
        [media_type] -> normalize_json_media_type(media_type, "")
        [media_type, charset] -> normalize_json_media_type(media_type, charset)
        _ -> :error
      end
    else
      :error
    end
  end

  defp normalize_json_media_type(media_type, charset) do
    media_type = String.downcase(media_type)
    charset = String.downcase(charset)
    json? = media_type == "application/json" or String.ends_with?(media_type, "+json")

    if json? and charset in ["", "charset=utf-8"],
      do: {:ok, media_type <> if(charset == "", do: "", else: ";charset=utf-8")},
      else: :error
  end

  defp authenticate(values, authenticated) do
    Repo.transaction(fn ->
      organization =
        Organization
        |> where([o], o.id == ^authenticated.organization_id)
        |> lock("FOR UPDATE")
        |> Repo.one!()

      source =
        Source
        |> where([s], s.id == ^authenticated.source_id and s.organization_id == ^organization.id)
        |> lock("FOR UPDATE")
        |> Repo.one!()

      agent =
        Agent
        |> where(
          [a],
          a.id == ^authenticated.agent_id and a.source_id == ^source.id and
            a.organization_id == ^organization.id
        )
        |> lock("FOR UPDATE")
        |> Repo.one!()

      credential =
        AgentCredential
        |> where(
          [c],
          c.id == ^authenticated.id and c.agent_id == ^agent.id and c.source_id == ^source.id and
            c.organization_id == ^organization.id
        )
        |> lock("FOR UPDATE")
        |> Repo.one!()

      now = Renga.Time.utc_now_ms()

      unless organization.status == "active" and source.status == "active" and
               agent.status == "active" and
               credential.status == "active" and
               DateTime.compare(credential.expires_at, now) == :gt and
               credential.credential_id == values.credential_id and
               credential.public_key == authenticated.public_key and
               agent.installation_id == values.installation_id,
             do: Repo.rollback(:unauthorized)

      %EnrollmentReplay{organization_id: organization.id, agent_credential_id: credential.id}
      |> EnrollmentReplay.changeset(%{
        kind: "runtime_nonce",
        value_hash: :crypto.hash(:sha256, values.nonce),
        expires_at: DateTime.add(now, @skew_seconds * 2, :second)
      })
      |> insert_runtime_nonce!()

      {organization, source, agent, credential}
    end)
  rescue
    Ecto.NoResultsError -> {:error, :unauthorized}
  end

  defp insert_runtime_nonce!(changeset) do
    case Repo.insert(changeset) do
      {:ok, replay} ->
        replay

      {:error, %Ecto.Changeset{} = changeset} ->
        if replay_conflict?(changeset) do
          Repo.rollback(:unauthorized)
        else
          raise Ecto.InvalidChangesetError, action: :insert, changeset: changeset
        end
    end
  end

  defp replay_conflict?(changeset) do
    Enum.any?(changeset.errors, fn
      {:value_hash, {_message, options}} ->
        options[:constraint] == :unique and
          options[:constraint_name] == "enrollment_replays_credential_index"

      _ ->
        false
    end)
  end

  defp credential_for(id), do: Repo.get_by(AgentCredential, credential_id: id)

  defp verify(key, signature, transcript),
    do: :crypto.verify(:eddsa, :none, transcript, signature, [key, :ed25519])

  defp one_header(conn, name) do
    case get_req_header(conn, name) do
      [value] when value != "" -> {:ok, value}
      _ -> :error
    end
  end

  defp decode_exact(value, size) do
    case Base.url_decode64(value, padding: false) do
      {:ok, decoded} when byte_size(decoded) == size -> canonical_decoded(value, decoded)
      _ -> :error
    end
  end

  defp decode_min(value, size) do
    case Base.url_decode64(value, padding: false) do
      {:ok, decoded} when byte_size(decoded) >= size -> canonical_decoded(value, decoded)
      _ -> :error
    end
  end

  defp canonical_decoded(encoded, decoded) do
    if Base.url_encode64(decoded, padding: false) == encoded, do: {:ok, decoded}, else: :error
  end

  defp unauthorized(conn) do
    conn
    |> put_status(:unauthorized)
    |> json(%{errors: [%{path: "authorization", message: "is invalid or missing"}]})
    |> halt()
  end
end
