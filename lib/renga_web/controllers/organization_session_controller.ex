defmodule RengaWeb.OrganizationSessionController do
  use RengaWeb, :controller

  alias RengaWeb.UserAuth

  def create(conn, %{"organization" => %{"id" => organization_id}}) do
    conn = UserAuth.put_current_organization(conn, organization_id)

    if conn.assigns.current_scope.organization_id == organization_id do
      redirect(conn, to: ~p"/inventory")
    else
      conn
      |> put_flash(:error, "You do not have access to that organization.")
      |> redirect(to: ~p"/organizations")
    end
  end
end
