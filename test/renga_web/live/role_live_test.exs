defmodule RengaWeb.RoleLiveTest do
  use RengaWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Renga.AccountsFixtures
  import Renga.InventoryFixtures

  alias Renga.Accounts
  alias Renga.Roles

  setup do
    organization = organization_fixture()
    {admin_conn, admin} = member(organization, "admin")
    {member_conn, _member} = member(organization, "member")
    %{admin: admin, admin_conn: admin_conn, member_conn: member_conn}
  end

  test "admins define, edit, and delete a custom role", context do
    {:ok, view, _html} = live(context.admin_conn, ~p"/settings/roles")

    assert has_element?(view, "#built-in-role-viewer", "inventory.read")
    # Owner-only and reserved permissions are not offered to an admin.
    refute has_element?(view, "#role-permission-organization\\.export")
    refute has_element?(view, "#role-permission-members\\.manage")

    view
    |> form("#role-form", role: %{name: "Network", permissions: [""]})
    |> render_submit()

    assert has_element?(view, "#role-form", "choose at least one permission")

    view
    |> form("#role-form",
      role: %{name: "Network", permissions: ["", "ipam.edit", "topology.edit"]}
    )
    |> render_submit()

    [role] = Roles.list_roles(context.admin)
    assert role.permissions == ["ipam.edit", "topology.edit"]
    assert has_element?(view, "#role-#{role.id}", "ipam.edit, topology.edit")

    view |> element("#role-#{role.id}-edit") |> render_click()

    view
    |> form("#role-form", role: %{name: "   ", permissions: ["topology.edit"]})
    |> render_submit()

    assert has_element?(view, "#role-form", "can't be blank")
    assert Process.alive?(view.pid)

    view
    |> form("#role-form", role: %{name: "Network", permissions: ["", "topology.edit"]})
    |> render_submit()

    assert has_element?(view, "#role-#{role.id}", "topology.edit")
    refute has_element?(view, "#role-#{role.id}", "ipam.edit")

    render_click(view, "delete", %{id: role.id})
    refute has_element?(view, "#role-#{role.id}")
  end

  test "members read roles without controls", context do
    {:ok, view, _html} = live(context.member_conn, ~p"/settings/roles")

    assert has_element?(view, "#built-in-role-owner")
    refute has_element?(view, "#new-role")
    refute has_element?(view, "#role-panel")
  end

  defp member(organization, role) do
    user = user_fixture()
    organization_membership_fixture(user, organization, %{role: role})

    conn =
      build_conn()
      |> log_in_user(user)
      |> put_session(:current_organization_id, organization.id)

    {conn, Accounts.scope_for_user(user, organization.id)}
  end
end
