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

    test "a stale member-removal event without an active group leaves the view alive", context do
      {:ok, staging} = ResourceGroups.create_group(context.admin, %{name: "Staging"})
      {:ok, 1} = ResourceGroups.add_members(context.admin, staging, [context.web.id])
      {:ok, view, _html} = live(context.admin_conn, ~p"/settings/groups")

      assert render_click(view, "remove_member", %{"id" => context.web.id}) =~
               "Choose the group again before removing members"

      view |> element("#group-#{staging.id}-edit") |> render_click()

      view
      |> form("#group-form", group: %{name: "Renamed"})
      |> render_submit()

      assert render_click(view, "remove_member", %{"id" => context.web.id}) =~
               "Choose the group again before removing members"

      assert [%{id: resource_id}] = ResourceGroups.list_members(context.admin, staging)
      assert resource_id == context.web.id
    end

    test "a stale removal event cannot remove a member from a newly edited group", context do
      {:ok, first} = ResourceGroups.create_group(context.admin, %{name: "First"})
      {:ok, second} = ResourceGroups.create_group(context.admin, %{name: "Second"})
      {:ok, 1} = ResourceGroups.add_members(context.admin, first, [context.web.id])
      {:ok, 1} = ResourceGroups.add_members(context.admin, second, [context.web.id])
      {:ok, view, _html} = live(context.admin_conn, ~p"/settings/groups")

      view |> element("#group-#{first.id}-edit") |> render_click()
      view |> element("#group-#{second.id}-edit") |> render_click()

      assert render_click(view, "remove_member", %{
               "id" => context.web.id,
               "group_id" => first.id
             }) =~ "Choose the group again before removing members"

      assert [%{id: resource_id}] = ResourceGroups.list_members(context.admin, first)
      assert resource_id == context.web.id
      assert [%{id: ^resource_id}] = ResourceGroups.list_members(context.admin, second)

      render_click(view, "remove_member", %{
        "id" => context.web.id,
        "group_id" => second.id
      })

      assert [%{id: ^resource_id}] = ResourceGroups.list_members(context.admin, first)
      assert ResourceGroups.list_members(context.admin, second) == []
    end
  end

  describe "resource page" do
    setup context do
      {:ok, set} =
        ResourceGroups.create_group_set(context.admin, %{name: "Environment", exclusive: true})

      {:ok, production} =
        ResourceGroups.create_group(context.admin, %{name: "Production", group_set_id: set.id})

      {:ok, staging} =
        ResourceGroups.create_group(context.admin, %{name: "Staging", group_set_id: set.id})

      %{production: production, staging: staging}
    end

    test "admins add, move within a set, and remove groups", context do
      {:ok, view, _html} = live(context.admin_conn, ~p"/inventory/#{context.web.id}")

      view
      |> form("#resource-group-form", group: %{id: context.production.id})
      |> render_submit()

      assert has_element?(view, "#resource-group-#{context.production.id}", "Environment")

      # Choosing the sibling moves the resource instead of conflicting.
      view
      |> form("#resource-group-form", group: %{id: context.staging.id})
      |> render_submit()

      assert has_element?(view, "#resource-group-#{context.staging.id}")
      refute has_element?(view, "#resource-group-#{context.production.id}")

      view |> element("#resource-group-#{context.staging.id}-remove") |> render_click()
      refute has_element?(view, "#resource-group-#{context.staging.id}")
    end

    test "members see the groups but cannot change them", context do
      {:ok, 1} = ResourceGroups.add_members(context.admin, context.staging, [context.web.id])
      {:ok, view, _html} = live(context.member_conn, ~p"/inventory/#{context.web.id}")

      assert has_element?(view, "#resource-group-#{context.staging.id}", "Staging")
      refute has_element?(view, "#resource-group-form")
      refute has_element?(view, "#resource-group-#{context.staging.id}-remove")

      assert render_click(view, "remove_from_group", %{"id" => context.staging.id}) =~
               "requires the owner or admin role"

      assert [%{direct: true}] =
               ResourceGroups.list_resource_groups(context.admin, context.web.id)
    end

    test "adding a sibling in a non-exclusive set keeps the existing membership", context do
      {:ok, customers} = ResourceGroups.create_group_set(context.admin, %{name: "Customer"})

      {:ok, acme} =
        ResourceGroups.create_group(context.admin, %{name: "Acme", group_set_id: customers.id})

      {:ok, globex} =
        ResourceGroups.create_group(context.admin, %{name: "Globex", group_set_id: customers.id})

      {:ok, 1} = ResourceGroups.add_members(context.admin, acme, [context.web.id])
      {:ok, view, _html} = live(context.admin_conn, ~p"/inventory/#{context.web.id}")

      view
      |> form("#resource-group-form", group: %{id: globex.id})
      |> render_submit()

      assert has_element?(view, "#resource-group-#{acme.id}")
      assert has_element?(view, "#resource-group-#{globex.id}")
    end
  end

  describe "inventory list" do
    setup context do
      {:ok, db} = Inventory.create_resource(context.admin, %{kind: "server", name: "db-01"})
      {:ok, staging} = ResourceGroups.create_group(context.admin, %{name: "Staging"})
      %{db: db, staging: staging}
    end

    test "filters by group and adds or removes the selection in bulk", context do
      %{web: web, db: db, staging: staging} = context

      {:ok, view, _html} =
        live(context.admin_conn, ~p"/inventory?#{[sel: "#{web.id},#{db.id}"]}")

      view
      |> form("#bulk-group-form", group: staging.id)
      |> put_submitter("#bulk-group-add")
      |> render_submit()

      assert ResourceGroups.list_members(context.admin, staging) |> length() == 2

      {:ok, view, _html} =
        live(context.admin_conn, ~p"/inventory?#{[in: staging.id, sel: web.id]}")

      assert has_element?(view, "#chip-group", "Staging")
      assert has_element?(view, "#resources-#{web.id}")
      assert has_element?(view, "#bulk-group-select option[selected][value='#{staging.id}']")

      view
      |> form("#bulk-group-form", group: staging.id)
      |> put_submitter("#bulk-group-remove")
      |> render_submit()

      assert [%{id: id}] = ResourceGroups.list_members(context.admin, staging)
      assert id == db.id
      refute has_element?(view, "#resources-#{web.id}")
    end

    test "a bulk add that breaks an exclusive set changes nothing", context do
      {:ok, set} =
        ResourceGroups.create_group_set(context.admin, %{name: "Environment", exclusive: true})

      {:ok, production} =
        ResourceGroups.create_group(context.admin, %{name: "Production", group_set_id: set.id})

      {:ok, _staging} =
        ResourceGroups.update_group(context.admin, context.staging, %{group_set_id: set.id})

      {:ok, 1} = ResourceGroups.add_members(context.admin, production, [context.web.id])

      {:ok, view, _html} =
        live(context.admin_conn, ~p"/inventory?#{[sel: "#{context.web.id},#{context.db.id}"]}")

      html =
        view
        |> form("#bulk-group-form", group: context.staging.id)
        |> put_submitter("#bulk-group-add")
        |> render_submit()

      assert html =~ "web-01 would be in both Production and Staging"
      assert ResourceGroups.list_members(context.admin, context.staging) == []
    end

    test "members cannot change groups in bulk", context do
      {:ok, 1} = ResourceGroups.add_members(context.admin, context.staging, [context.db.id])

      {:ok, view, _html} =
        live(context.member_conn, ~p"/inventory?#{[sel: context.web.id]}")

      refute has_element?(view, "#bulk-group-form")

      assert render_submit(view, "bulk_group", %{
               "group" => context.staging.id,
               "action" => "add"
             }) =~ "requires the owner or admin role"

      assert [%{name: "db-01"}] = ResourceGroups.list_members(context.admin, context.staging)
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
