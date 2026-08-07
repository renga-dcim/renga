defmodule RengaWeb.OrganizationLiveTest do
  use RengaWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Renga.AccountsFixtures
  import Renga.InventoryFixtures

  alias Renga.Accounts

  setup %{conn: conn} do
    user = user_fixture()
    %{conn: log_in_user(conn, user), user: user}
  end

  test "lets a signed-in user create and select an organization", %{conn: conn, user: user} do
    {:ok, view, _html} = live(conn, ~p"/organizations")

    assert has_element?(view, "#organization-selector")
    assert has_element?(view, "#organizations-empty")
    assert has_element?(view, "#organization-form")

    view
    |> form("#organization-form", %{
      "organization" => %{"name" => "Acme Operations", "slug" => "acme-operations"}
    })
    |> render_submit()

    assert [membership] = Accounts.list_user_organization_memberships(user)
    organization = membership.organization
    assert has_element?(view, "#organization-#{organization.id}", "Acme Operations")
    assert has_element?(view, "#select-organization-#{organization.id}")

    conn =
      post(conn, ~p"/organizations/select", %{
        "organization" => %{"id" => organization.id}
      })

    assert get_session(conn, :current_organization_id) == organization.id
    assert redirected_to(conn) == ~p"/inventory"
  end

  test "lists only the signed-in user's active memberships", %{conn: conn, user: user} do
    organization = organization_fixture(%{name: "Visible Organization"})
    organization_membership_fixture(user, organization)
    foreign_organization = organization_fixture(%{name: "Hidden Organization"})

    {:ok, view, _html} = live(conn, ~p"/organizations")

    assert has_element?(view, "#organization-#{organization.id}", "Visible Organization")
    refute has_element?(view, "#organization-selector", "Hidden Organization")
    refute has_element?(view, "#select-organization-#{foreign_organization.id}")
  end

  test "rejects selecting an organization without membership", %{conn: conn} do
    organization = organization_fixture(%{name: "Foreign Organization"})

    conn =
      post(conn, ~p"/organizations/select", %{
        "organization" => %{"id" => organization.id}
      })

    assert get_session(conn, :current_organization_id) == nil
    assert redirected_to(conn) == ~p"/organizations"

    assert Phoenix.Flash.get(conn.assigns.flash, :error) ==
             "You do not have access to that organization."
  end

  test "requires authentication", %{conn: conn} do
    conn = conn |> recycle() |> init_test_session(%{})

    assert {:error, {:redirect, %{to: "/users/log-in"}}} = live(conn, ~p"/organizations")
  end
end
