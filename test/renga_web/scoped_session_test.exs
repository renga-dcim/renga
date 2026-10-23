defmodule RengaWeb.ScopedSessionTest do
  use RengaWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Renga.AccountsFixtures
  import Renga.InventoryFixtures

  setup %{conn: conn} do
    user = user_fixture() |> set_password()
    home = organization_fixture(%{name: "Home Org"})
    other = organization_fixture(%{name: "Other Org"})
    organization_membership_fixture(user, home)
    organization_membership_fixture(user, other)

    # As an organization provider's sign-in will issue it.
    conn =
      conn
      |> log_in_user(%{user | session_organization_id: home.id})
      |> put_session(:current_organization_id, home.id)

    %{conn: conn, user: user, home: home, other: other}
  end

  test "the organization picker offers only the session's organization", %{
    conn: conn,
    home: home,
    other: other
  } do
    {:ok, view, html} = live(conn, ~p"/organizations")

    assert has_element?(view, "#select-organization-#{home.id}")
    refute has_element?(view, "#select-organization-#{other.id}")
    refute html =~ "Other Org"
    assert has_element?(view, "#scoped-session-organizations")
    refute has_element?(view, "#organization-form")
  end

  test "with no organization left, the picker doesn't offer to create one", %{conn: conn} do
    conn =
      log_in_user(conn, %{user_fixture() | session_organization_id: organization_fixture().id})

    {:ok, view, _html} = live(conn, ~p"/organizations")

    assert has_element?(view, "#organizations-empty", "No organizations yet.")
    refute has_element?(view, "#organizations-empty", "Create the first one")
  end

  test "selecting another organization is refused", %{conn: conn, home: home, other: other} do
    conn = post(conn, ~p"/organizations/select", %{"organization" => %{"id" => other.id}})

    assert get_session(conn, :current_organization_id) == home.id
    assert redirected_to(conn) == ~p"/organizations"
  end

  test "a stale selection of another organization opens nothing", %{conn: conn, other: other} do
    conn = put_session(conn, :current_organization_id, other.id)

    assert {:error, {:redirect, %{to: "/organizations"}}} = live(conn, ~p"/inbox")
  end

  test "account settings explain and refuse sign-in changes", %{conn: conn, user: user} do
    {:ok, view, _html} = live(conn, ~p"/users/settings")

    assert has_element?(view, "#scoped_session_notice")
    assert render_click(view, "remove_password", %{}) =~ "Sign in another way"
    refute has_element?(view, "#recheck")
    assert Renga.Repo.reload!(user).hashed_password
  end
end
