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
         {:ok, %Source{organization: %Organization{} = organization} = source} <-
           Inventory.authenticate_source_token(token) do
      scope = Accounts.scope_for(organization)

      conn
      |> assign(:current_source, source)
      |> assign(:current_scope, scope)
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
end
