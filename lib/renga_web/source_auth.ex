defmodule RengaWeb.SourceAuth do
  @moduledoc """
  Authenticates organization intake keys or temporary legacy source tokens for
  the agent JSON API.
  """

  import Phoenix.Controller
  import Plug.Conn

  alias Renga.Accounts
  alias Renga.Accounts.Organization
  alias Renga.Inventory
  alias Renga.Inventory.IntakeApiKey
  alias Renga.Inventory.Source

  def init(opts), do: opts

  def call(conn, _opts) do
    with {:ok, token} <- bearer_token(conn),
         {:ok, installation_id} <- installation_id(conn),
         {:ok, credential, %Organization{} = organization} <- authenticate(token) do
      conn =
        conn
        |> assign(:current_scope, Accounts.scope_for(organization))
        |> assign(:current_installation_id, installation_id)

      assign_credential(conn, credential)
    else
      _invalid ->
        conn
        |> put_status(:unauthorized)
        |> json(%{errors: [%{path: "authorization", message: "is invalid or missing"}]})
        |> halt()
    end
  end

  defp authenticate(token) do
    case Inventory.authenticate_intake_api_key(token) do
      {:ok, %IntakeApiKey{organization: organization} = key} ->
        {:ok, key, organization}

      :error ->
        case Inventory.authenticate_source_token(token) do
          {:ok, %Source{organization: organization} = source} -> {:ok, source, organization}
          :error -> :error
        end
    end
  end

  defp assign_credential(conn, %IntakeApiKey{} = key),
    do: assign(conn, :current_intake_api_key, key)

  defp assign_credential(conn, %Source{} = source), do: assign(conn, :current_source, source)

  defp bearer_token(conn) do
    case get_req_header(conn, "authorization") do
      ["Bearer " <> token] when token != "" -> {:ok, token}
      _missing_or_invalid -> :error
    end
  end

  defp installation_id(conn) do
    with [installation_id] <- get_req_header(conn, "x-renga-installation-id"),
         {:ok, normalized} <- Ecto.UUID.cast(installation_id) do
      {:ok, normalized}
    else
      _missing_or_invalid -> :error
    end
  end
end
