defmodule RengaWeb.PageController do
  use RengaWeb, :controller

  alias Renga.Accounts.Scope

  def home(conn, _params) do
    redirect(conn, to: destination(conn.assigns.current_scope))
  end

  defp destination(%Scope{organization_id: organization_id}) when is_binary(organization_id),
    do: ~p"/inventory"

  defp destination(%Scope{user: %Renga.Accounts.User{}}), do: ~p"/organizations"
  defp destination(_scope), do: ~p"/users/log-in"
end
