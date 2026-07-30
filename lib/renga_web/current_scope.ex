defmodule RengaWeb.CurrentScope do
  @moduledoc """
  Helpers for assigning the current organization scope in controllers and LiveViews.
  """

  import Plug.Conn, only: [delete_session: 2, get_session: 2, put_session: 3]

  alias Renga.Accounts
  alias Renga.Accounts.Organization
  alias Renga.Accounts.Scope

  @session_key "current_organization_id"

  def fetch_current_scope(conn, _opts) do
    organization =
      conn
      |> get_session(@session_key)
      |> get_session_organization()

    assign_current_scope(conn, organization)
  end

  def put_current_organization(conn, %Organization{} = organization) do
    conn
    |> put_session(@session_key, organization.id)
    |> assign_current_scope(organization)
  end

  def clear_current_organization(conn) do
    conn
    |> delete_session(@session_key)
    |> assign_scope(nil)
  end

  def assign_current_scope(conn_or_socket, nil) do
    assign_scope(conn_or_socket, nil)
  end

  def assign_current_scope(conn_or_socket, %Organization{} = organization) do
    assign_scope(conn_or_socket, Accounts.scope_for(organization))
  end

  def assign_current_scope(conn_or_socket, %Scope{} = scope) do
    assign_scope(conn_or_socket, scope)
  end

  def on_mount(:default, _params, session, socket) do
    organization =
      session
      |> Map.get(@session_key)
      |> get_session_organization()

    {:cont, assign_current_scope(socket, organization)}
  end

  defp get_session_organization(nil), do: nil
  defp get_session_organization(""), do: nil

  defp get_session_organization(id) when is_binary(id), do: Accounts.get_organization!(id)

  defp assign_scope(%Plug.Conn{} = conn, scope), do: Plug.Conn.assign(conn, :current_scope, scope)

  defp assign_scope(socket, scope), do: Phoenix.Component.assign(socket, :current_scope, scope)
end
