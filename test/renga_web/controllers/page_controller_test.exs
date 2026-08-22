defmodule RengaWeb.PageControllerTest do
  use RengaWeb.ConnCase, async: true

  import Renga.AccountsFixtures
  import Renga.InventoryFixtures

  test "GET / sends signed-out visitors to login", %{conn: conn} do
    conn = get(conn, ~p"/")
    assert redirected_to(conn) == ~p"/users/log-in"
  end

  test "GET / sends signed-in users without a selected organization to the chooser", %{conn: conn} do
    conn = conn |> log_in_user(user_fixture()) |> get(~p"/")

    assert redirected_to(conn) == ~p"/organizations"
  end

  test "GET / sends an organization-scoped user to inventory", %{conn: conn} do
    user = user_fixture()
    organization = organization_fixture()
    organization_membership_fixture(user, organization)

    conn =
      conn
      |> log_in_user(user)
      |> put_session(:current_organization_id, organization.id)
      |> get(~p"/")

    assert redirected_to(conn) == ~p"/inventory"
  end
end
