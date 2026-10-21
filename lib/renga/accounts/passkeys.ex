defmodule Renga.Accounts.Passkeys do
  @moduledoc """
  Passkey registration and assertion (RFD 19, "Credentials").

  Verification uses the pinned `wax_` library. Renga requires user
  verification on every ceremony, so a passkey alone is two factors: the
  device and its PIN or biometric. It requests no attestation and accepts any
  authenticator. The relying party is the deployment's configured origin and
  host (`config :renga, :webauthn`).

  Each ceremony signs a challenge stored in `webauthn_challenges`.
  Verification deletes it first, so a response is accepted at most once, and
  a challenge issued for one purpose or user cannot complete another.
  """

  import Ecto.Query

  alias Renga.Accounts.SecurityEvent
  alias Renga.Accounts.User
  alias Renga.Accounts.UserPasskey
  alias Renga.Accounts.WebAuthnChallenge
  alias Renga.Repo

  @challenge_seconds 5 * 60
  @purposes ~w(register sign_in second_step recheck)
  # ES256, then RS256 for authenticators that only offer RSA.
  @algorithms [-7, -257]

  @doc "The deployment's WebAuthn origin and relying party ID."
  def relying_party do
    origin = Application.fetch_env!(:renga, :webauthn)[:origin]
    %{origin: origin, rp_id: URI.parse(origin).host}
  end

  @doc "The account's passkeys, oldest first."
  def list(%User{id: user_id}) do
    UserPasskey
    |> where(user_id: ^user_id)
    |> order_by(asc: :inserted_at)
    |> Repo.all()
  end

  @doc "Whether the account holds a passkey."
  def any?(%User{id: user_id}), do: Repo.exists?(where(UserPasskey, user_id: ^user_id))

  @doc """
  Starts registering a passkey for `user`. Returns the options for
  `navigator.credentials.create()`, with binary fields base64url-encoded.
  """
  def registration_options(%User{} = user) do
    challenge = new_challenge("register", user)
    %{rp_id: rp_id} = relying_party()

    %{
      challenge: encode(challenge.bytes),
      rp: %{id: rp_id, name: "Renga"},
      user: %{id: encode(user_handle(user)), name: user.email, displayName: user.email},
      pubKeyCredParams: Enum.map(@algorithms, &%{type: "public-key", alg: &1}),
      authenticatorSelection: %{residentKey: "required", userVerification: "required"},
      attestation: "none",
      excludeCredentials: Enum.map(list(user), &descriptor/1),
      timeout: @challenge_seconds * 1000
    }
  end

  @doc """
  Finishes registering a passkey from the browser's response. The caller
  checks the account re-check first.
  """
  def register(%User{} = user, response, name \\ "Passkey") do
    with {:ok, client_data_json} <- decode_field(response, "clientDataJSON"),
         {:ok, attestation_object} <- decode_field(response, "attestationObject"),
         {:ok, challenge} <- take_challenge(client_data_json, "register", user),
         {:ok, {auth_data, _attestation}} <-
           verify(fn ->
             Wax.register(
               attestation_object,
               client_data_json,
               wax_challenge(challenge, :register)
             )
           end),
         {:ok, credential} <- attested_credential(auth_data),
         :ok <- check_algorithm(credential.credential_public_key) do
      %UserPasskey{
        user_id: user.id,
        credential_id: credential.credential_id,
        public_key: :erlang.term_to_binary(credential.credential_public_key),
        sign_count: auth_data.sign_count,
        transports: transports(response),
        backup_eligible: auth_data.flag_backup_eligible,
        backed_up: auth_data.flag_credential_backed_up
      }
      |> UserPasskey.name_changeset(%{name: name})
      |> Ecto.Changeset.unique_constraint(:credential_id)
      |> Repo.insert()
      |> case do
        {:ok, passkey} ->
          record_event(user, "passkey_added", %{"passkey_id" => passkey.id})
          {:ok, passkey}

        {:error, _changeset} ->
          {:error, :already_registered}
      end
    else
      {:error, %{__exception__: true}} -> {:error, :invalid_response}
      {:error, _reason} = error -> error
    end
  end

  @doc """
  Options for `navigator.credentials.get()`. With a user, only that user's
  passkeys are allowed (the second step and the re-check); without one the
  browser offers any discoverable passkey for this site (sign-in, including
  autofill).
  """
  def authentication_options(purpose, user \\ nil)
      when purpose in ["sign_in", "second_step", "recheck"] do
    challenge = new_challenge(purpose, user)

    %{
      challenge: encode(challenge.bytes),
      rpId: relying_party().rp_id,
      allowCredentials: if(user, do: Enum.map(list(user), &descriptor/1), else: []),
      userVerification: "required",
      timeout: @challenge_seconds * 1000
    }
  end

  @doc """
  Verifies an assertion. With `user`, the passkey must be theirs; without,
  the passkey decides who signs in. Returns the user and passkey.
  """
  def authenticate(purpose, response, user \\ nil) do
    with {:ok, credential_id} <- decode_field(response, "rawId"),
         {:ok, auth_data_bin} <- decode_field(response, "authenticatorData"),
         {:ok, signature} <- decode_field(response, "signature"),
         {:ok, client_data_json} <- decode_field(response, "clientDataJSON"),
         {:ok, challenge} <- take_challenge(client_data_json, purpose, user),
         %UserPasskey{} = passkey <- passkey_for(credential_id, user) || {:error, :unknown},
         cose_key = :erlang.binary_to_term(passkey.public_key, [:safe]),
         :ok <- check_user_handle(purpose, response, passkey),
         {:ok, auth_data} <-
           verify(fn ->
             Wax.authenticate(
               credential_id,
               auth_data_bin,
               signature,
               client_data_json,
               wax_challenge(challenge, :authenticate),
               [{credential_id, cose_key}]
             )
           end),
         :ok <- record_use(passkey, auth_data) do
      {:ok, Repo.get!(User, passkey.user_id), Repo.get!(UserPasskey, passkey.id)}
    else
      {:error, %{__exception__: true}} ->
        fail(user)

      {:error, _reason} = error ->
        fail(user)
        error

      _ ->
        fail(user)
    end
  end

  defp fail(nil), do: {:error, :invalid_response}

  defp fail(%User{} = user) do
    record_event(user, "passkey_failed")
    {:error, :invalid_response}
  end

  @doc "Renames a passkey."
  def rename(%User{id: user_id}, passkey_id, name) do
    case Repo.get_by(UserPasskey, id: passkey_id, user_id: user_id) do
      nil -> {:error, :not_found}
      passkey -> passkey |> UserPasskey.name_changeset(%{name: name}) |> Repo.update()
    end
  end

  @doc "Removes a passkey. The caller checks the account re-check first."
  def delete(%User{id: user_id} = user, passkey_id) do
    case Repo.get_by(UserPasskey, id: passkey_id, user_id: user_id) do
      nil ->
        {:error, :not_found}

      passkey ->
        Repo.delete!(passkey)
        record_event(user, "passkey_removed", %{"passkey_id" => passkey.id})
        {:ok, passkey}
    end
  end

  defp new_challenge(purpose, user) when purpose in @purposes do
    now = Renga.Time.utc_now_ms()
    Repo.delete_all(where(WebAuthnChallenge, [challenge], challenge.expires_at < ^now))

    Repo.insert!(%WebAuthnChallenge{
      bytes: :crypto.strong_rand_bytes(32),
      purpose: purpose,
      user_id: user && user.id,
      expires_at: DateTime.add(now, @challenge_seconds, :second)
    })
  end

  # Deletes the challenge the response signed, so it can be used only once,
  # and checks it was issued for this purpose and user.
  defp take_challenge(client_data_json, purpose, user) do
    with {:ok, %{"challenge" => encoded} = client_data} when is_binary(encoded) <-
           Jason.decode(client_data_json),
         # Wax does not check crossOrigin; a ceremony run inside another
         # site's frame is refused rather than left to the framing policy.
         false <- Map.get(client_data, "crossOrigin", false),
         {:ok, bytes} <- Base.url_decode64(encoded, padding: false) do
      now = Renga.Time.utc_now_ms()
      user_id = user && user.id

      WebAuthnChallenge
      |> where(bytes: ^bytes, purpose: ^purpose)
      |> where([challenge], challenge.expires_at > ^now)
      |> select([challenge], challenge)
      |> Repo.delete_all()
      |> case do
        {1, [%WebAuthnChallenge{user_id: ^user_id} = challenge]} -> {:ok, challenge}
        _ -> {:error, :invalid_challenge}
      end
    else
      _ -> {:error, :invalid_response}
    end
  end

  defp wax_challenge(%WebAuthnChallenge{} = challenge, type) do
    %{origin: origin, rp_id: rp_id} = relying_party()

    opts = [
      bytes: challenge.bytes,
      origin: origin,
      rp_id: rp_id,
      user_verification: "required",
      attestation: "none",
      verify_trust_root: false,
      timeout: @challenge_seconds
    ]

    case type do
      :register -> Wax.new_registration_challenge(opts)
      :authenticate -> Wax.new_authentication_challenge(opts)
    end
  end

  defp passkey_for(credential_id, nil), do: Repo.get_by(UserPasskey, credential_id: credential_id)

  defp passkey_for(credential_id, %User{id: user_id}),
    do: Repo.get_by(UserPasskey, credential_id: credential_id, user_id: user_id)

  # Wax raises on some malformed client data and attestation shapes; those
  # are refused like any other invalid response. Nothing here touches the
  # database, so only parsing errors can arrive.
  defp verify(fun) do
    fun.()
  rescue
    _exception -> {:error, :invalid_response}
  end

  # Wax accepts a "none" attestation without attested credential data.
  defp attested_credential(%{attested_credential_data: %{} = credential}), do: {:ok, credential}
  defp attested_credential(_auth_data), do: {:error, :invalid_response}

  # WebAuthn §7.1 step 16: the new key must use an algorithm Renga offered.
  defp check_algorithm(%{3 => alg}) when alg in @algorithms, do: :ok
  defp check_algorithm(_cose_key), do: {:error, :invalid_response}

  # WebAuthn §7.2 step 6: the user handle names the passkey's owner. A
  # discoverable sign-in must send it; with a known user it may be absent.
  defp check_user_handle(purpose, response, %UserPasskey{user_id: user_id}) do
    expected = user_handle(%User{id: user_id})

    case response["userHandle"] do
      nil when purpose != "sign_in" ->
        :ok

      handle when is_binary(handle) ->
        case Base.url_decode64(handle, padding: false) do
          {:ok, ^expected} -> :ok
          _ -> {:error, :user_handle}
        end

      _ ->
        {:error, :user_handle}
    end
  end

  # A counter that stops increasing suggests a cloned authenticator. Synced
  # passkeys always report zero, which is allowed. The check and the update
  # are one statement, so concurrent assertions cannot move it backwards.
  defp record_use(%UserPasskey{id: id}, auth_data) do
    new = auth_data.sign_count

    {count, _} =
      UserPasskey
      |> where(id: ^id)
      |> where([passkey], passkey.sign_count == 0 or passkey.sign_count < ^new)
      |> Repo.update_all(
        set: [
          sign_count: new,
          backed_up: auth_data.flag_credential_backed_up,
          last_used_at: Renga.Time.utc_now_ms()
        ]
      )

    if count == 1, do: :ok, else: {:error, :sign_count}
  end

  defp descriptor(%UserPasskey{} = passkey) do
    %{type: "public-key", id: encode(passkey.credential_id), transports: passkey.transports}
  end

  # A stable, opaque user handle: the account ID's sixteen bytes.
  defp user_handle(%User{id: id}), do: Ecto.UUID.dump!(id)

  defp transports(%{"transports" => transports}) when is_list(transports),
    do: transports |> Enum.filter(&is_binary/1) |> Enum.take(8)

  defp transports(_response), do: []

  defp decode_field(response, field) do
    with value when is_binary(value) <- response[field],
         {:ok, decoded} <- Base.url_decode64(value, padding: false) do
      {:ok, decoded}
    else
      _ -> {:error, :invalid_response}
    end
  end

  defp encode(bytes), do: Base.url_encode64(bytes, padding: false)

  defp record_event(user, kind, metadata \\ %{}) do
    Repo.insert!(%SecurityEvent{user_id: user.id, kind: kind, metadata: metadata})
  end
end
