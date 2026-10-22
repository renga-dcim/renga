defmodule RengaWeb.GroupLiveTest do
  use RengaWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Renga.AccountsFixtures
  import Renga.InventoryFixtures

  alias Renga.Inventory
  alias Renga.ResourceGroups

  setup do
    organization = organization_fixture()
    {admin_conn, admin} = member(organization, "admin")
    {member_conn, member} = member(organization, "member")
    {:ok, web} = Inventory.create_resource(admin, %{kind: "server", name: "web-01"})

    %{
      organization: organization,
      admin_conn: admin_conn,
      member_conn: member_conn,
      admin: admin,
      member: member,
      web: web
    }
  end

  describe "Settings → Groups" do
    test "admins define sets and groups, and delete them", context do
      {:ok, view, _html} = live(context.admin_conn, ~p"/settings/groups")

      assert has_element?(view, "#group-list-empty")

      view
      |> form("#group-set-form", group_set: %{name: "Environment", exclusive: "true"})
      |> render_submit()

      [set] = ResourceGroups.list_group_sets(context.admin)
      assert set.exclusive
      assert has_element?(view, "#group-set-#{set.id}", "Yes")

      view |> form("#group-form", group: %{name: ""}) |> render_submit()
      assert has_element?(view, "#group-form", "can't be blank")

      view
      |> form("#group-form", group: %{name: "Staging", group_set_id: set.id})
      |> render_submit()

      [group] = ResourceGroups.list_groups(context.admin)
      assert has_element?(view, "#group-#{group.id}", "Environment · exclusive")

      {:ok, 1} = ResourceGroups.add_members(context.admin, group, [context.web.id])
      {:ok, view, _html} = live(context.admin_conn, ~p"/settings/groups")
      assert has_element?(view, "#delete-group-#{group.id}", "1 resource will leave the group")

      view |> element("#group-#{group.id}-edit") |> render_click()
      assert has_element?(view, "#group-member-#{context.web.id}", "web-01")

      view |> element("#group-member-#{context.web.id}-remove") |> render_click()
      refute has_element?(view, "#group-member-#{context.web.id}")

      view |> element("#delete-group-#{group.id}-confirm") |> render_click()
      assert has_element?(view, "#group-list-empty")

      view |> element("#delete-group-set-#{set.id}-confirm") |> render_click()
      assert ResourceGroups.list_group_sets(context.admin) == []
    end

    test "moving a group into an exclusive set its members conflict with is refused", context do
      {:ok, set} =
        ResourceGroups.create_group_set(context.admin, %{name: "Environment", exclusive: true})

      {:ok, production} =
        ResourceGroups.create_group(context.admin, %{name: "Production", group_set_id: set.id})

      {:ok, legacy} = ResourceGroups.create_group(context.admin, %{name: "Legacy"})
      {:ok, 1} = ResourceGroups.add_members(context.admin, production, [context.web.id])
      {:ok, 1} = ResourceGroups.add_members(context.admin, legacy, [context.web.id])

      {:ok, view, _html} = live(context.admin_conn, ~p"/settings/groups")
      view |> element("#group-#{legacy.id}-edit") |> render_click()

      html =
        view
        |> form("#group-form", group: %{group_set_id: set.id})
        |> render_submit()

      assert html =~ "web-01 would be in both Legacy and Production, but Environment is exclusive"
    end

    test "members see only groups that hold a resource and cannot manage them", context do
      {:ok, staging} = ResourceGroups.create_group(context.admin, %{name: "Staging"})
      {:ok, _empty} = ResourceGroups.create_group(context.admin, %{name: "Empty"})
      {:ok, 1} = ResourceGroups.add_members(context.admin, staging, [context.web.id])

      {:ok, view, _html} = live(context.member_conn, ~p"/settings/groups")

      assert has_element?(view, "#group-list", "Staging")
      refute has_element?(view, "#group-list", "Empty")
      assert has_element?(view, "#groups-read-only")
      refute has_element?(view, "#new-group")
      refute has_element?(view, "#group-form")

      assert render_submit(view, "save", %{"group" => %{"name" => "Forged"}}) =~
               "requires the owner"

      assert length(ResourceGroups.list_groups(context.admin)) == 2
    end
  end

  defp member(organization, role) do
    user = user_fixture()
    organization_membership_fixture(user, organization, %{role: role})

    conn =
      build_conn()
      |> log_in_user(user)
      |> put_session(:current_organization_id, organization.id)

    {conn, Renga.Accounts.scope_for_user(user, organization.id)}
  end
end
