defmodule RengaWeb.RoleLiveTest do
  use RengaWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Renga.AccountsFixtures
  import Renga.InventoryFixtures

  alias Renga.Accounts
  alias Renga.Assignments
  alias Renga.Roles

  setup do
    organization = organization_fixture()
    {admin_conn, admin} = member(organization, "admin")
    {member_conn, member} = member(organization, "member")
    %{admin: admin, admin_conn: admin_conn, member: member, member_conn: member_conn}
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
    assert has_element?(view, "#role-#{role.id}-people", "Nobody")

    {:ok, _} =
      Assignments.assign(context.admin, context.admin.membership_id, %{"role" => role.id})

    {:ok, view, _html} = live(context.admin_conn, ~p"/settings/roles")
    assert has_element?(view, "#role-#{role.id}-people", "1 person")
    assert has_element?(view, "#delete-role-#{role.id}", "1 person with it will lose it")

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

  test "a connected page gains and loses temporary role management", context do
    {:ok, view, _html} = live(context.member_conn, ~p"/settings/roles")
    refute has_element?(view, "#new-role")

    {:ok, assignment} =
      Assignments.assign(context.admin, context.member.membership_id, %{"role" => "admin"})

    send(view.pid, {:inventory_changed, context.admin.organization_id})
    assert has_element?(view, "#new-role")
    assert has_element?(view, "#role-permission-ipam\\.edit")

    {:ok, _deleted} = Assignments.unassign(context.admin, assignment.id)
    send(view.pid, {:inventory_changed, context.admin.organization_id})
    refute has_element?(view, "#new-role")
    refute has_element?(view, "#role-panel")
  end

  test "a role deleted in another session closes and resets its editor", context do
    {:ok, role} =
      Roles.create_role(context.admin, %{
        "name" => "Temporary editor",
        "permissions" => ["ipam.edit"]
      })

    {:ok, view, _html} = live(context.admin_conn, ~p"/settings/roles")
    view |> element("#role-#{role.id}-edit") |> render_click()
    assert has_element?(view, "#role-form input[name='role[name]'][value='Temporary editor']")

    assert {:ok, _deleted} = Roles.delete_role(context.admin, role)
    send(view.pid, {:inventory_changed, context.admin.organization_id})

    assert_push_event(view, "close-overlay", %{id: "role-panel"})
    refute has_element?(view, "#role-form input[name='role[name]'][value='Temporary editor']")
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
