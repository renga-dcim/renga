defmodule RengaWeb.SourceAuth do
  @moduledoc """
  Authenticates source bearer tokens for the agent JSON API.
  """

  import Phoenix.Controller
  import Plug.Conn

  alias Renga.Accounts
  alias Renga.Accounts.Organization
  alias Renga.Inventory
  alias Renga.Inventory.Source

  def init(opts), do: opts

  def call(conn, _opts) do
    with {:ok, token} <- bearer_token(conn),
         {:ok, installation_id} <- installation_id(conn),
         {:ok, %Source{organization: %Organization{} = organization} = source} <-
           Inventory.authenticate_source_token(token) do
      scope = Accounts.scope_for(organization)

      conn
      |> assign(:current_source, source)
      |> assign(:current_scope, scope)
      |> assign(:current_installation_id, installation_id)
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
