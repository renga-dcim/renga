defmodule RengaWeb.IntakeAuth do
  @moduledoc """
  Authenticates organization intake keys for the agent JSON API and the
  agent socket.
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
         {:ok, scope, installation_id, key} <-
           authenticate(token, get_req_header(conn, "x-renga-installation-id")) do
      conn
      |> assign(:current_scope, scope)
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

  @doc """
  Checks an intake key and the installation ID an agent claims, given as the
  values of its `x-renga-installation-id` header, and records the contact.
  Every agent entry point authenticates through here, so they agree on what
  a valid caller is.
  """
  def authenticate(token, installation_header) when is_binary(token) do
    with {:ok, installation_id} <- installation_id(installation_header),
         {:ok, %IntakeApiKey{organization: %Organization{} = organization} = key} <-
           Inventory.authenticate_intake_api_key(token) do
      # Before the payload is judged, so a rejected report still counts.
      :ok = Inventory.record_intake_contact(key, installation_id)
      {:ok, Accounts.scope_for(organization), installation_id, key}
    else
      _invalid -> :error
    end
  end

  def authenticate(_token, _installation_header), do: :error

  defp bearer_token(conn) do
    case get_req_header(conn, "authorization") do
      ["Bearer " <> token] when token != "" -> {:ok, token}
      _missing_or_invalid -> :error
    end
  end

  defp installation_id([installation_id]), do: Ecto.UUID.cast(installation_id)
  defp installation_id(_missing_or_repeated), do: :error
end
