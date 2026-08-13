defmodule RengaWeb.IntakeAuth do
  @moduledoc """
  Authenticates organization intake keys for the agent JSON API.
  """

  import Phoenix.Controller
  import Plug.Conn

  alias Renga.Accounts
  alias Renga.Accounts.Organization
  alias Renga.Inventory
  alias Renga.Inventory.IntakeApiKey

  def init(opts), do: opts

  def call(conn, _opts) do
    with {:ok, token} <- bearer_token(conn),
         {:ok, installation_id} <- installation_id(conn),
         {:ok, %IntakeApiKey{organization: %Organization{} = organization} = key} <-
           Inventory.authenticate_intake_api_key(token) do
      conn
      |> assign(:current_scope, Accounts.scope_for(organization))
      |> assign(:current_installation_id, installation_id)
      |> assign(:current_intake_api_key, key)
    else
      _invalid ->
        conn
        |> put_status(:unauthorized)
        |> json(%{errors: [%{path: "authorization", message: "is invalid or missing"}]})
        |> halt()
    end
  end

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
