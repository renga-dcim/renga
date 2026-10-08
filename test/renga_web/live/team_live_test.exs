defmodule RengaWeb.TeamLiveTest do
  use RengaWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Renga.AccountsFixtures
  import Renga.InventoryFixtures

  alias Renga.Inventory
  alias Renga.Requests
  alias Renga.Teams

  setup do
    organization = organization_fixture()
    {admin_conn, admin} = member(organization, "admin")
    {member_conn, member} = member(organization, "member")
    {:ok, web} = Inventory.create_resource(admin, %{kind: "server", name: "web-01"})
    {:ok, db} = Inventory.create_resource(admin, %{kind: "server", name: "db-01"})

    %{
      organization: organization,
      admin_conn: admin_conn,
      member_conn: member_conn,
      admin: admin,
      member: member,
      web: web,
      db: db
    }
  end

  describe "Settings → Teams" do
    test "admins create, rename, and delete teams", context do
      {:ok, view, _html} = live(context.admin_conn, ~p"/settings/teams")

      assert has_element?(view, "#team-list-empty")

      view |> form("#team-form", team: %{name: ""}) |> render_submit()
      assert has_element?(view, "#team-form", "can't be blank")

      view
      |> form("#team-form", team: %{name: "Platform", description: "Runs the compute fleet"})
      |> render_submit()

      [team] = Teams.list_teams(context.admin)
      assert has_element?(view, "#team-#{team.id}", "Runs the compute fleet")

      view |> element("#team-#{team.id}-edit") |> render_click()
      view |> form("#team-form", team: %{name: "Platform Eng"}) |> render_submit()
      assert has_element?(view, "#team-#{team.id}", "Platform Eng")

      {:ok, _web} = Teams.set_owner(context.admin, context.web, team.id)
      {:ok, view, _html} = live(context.admin_conn, ~p"/settings/teams")

      assert has_element?(
               view,
               "#team-#{team.id} a[href='/inventory?owner=#{team.id}']",
               "1 resource"
             )

      assert has_element?(view, "#delete-team-#{team.id}", "1 resource will have no owner")

      view |> element("#delete-team-#{team.id}-confirm") |> render_click()
      assert has_element?(view, "#team-list-empty")
    end

    test "members read teams but cannot manage them", context do
      {:ok, _team} = Teams.create_team(context.admin, %{"name" => "Platform"})
      {:ok, view, _html} = live(context.member_conn, ~p"/settings/teams")

      assert has_element?(view, "#team-list", "Platform")
      assert has_element?(view, "#teams-read-only")
      refute has_element?(view, "#new-team")
      refute has_element?(view, "#team-form")

      assert render_submit(view, "save", %{"team" => %{"name" => "Forged"}}) =~
               "requires the owner"

      assert [_one] = Teams.list_teams(context.admin)
    end
  end

  describe "resource owner" do
    test "admins set and clear the owner from the resource page", context do
      {:ok, team} = Teams.create_team(context.admin, %{"name" => "Platform"})
      {:ok, view, _html} = live(context.admin_conn, ~p"/inventory/#{context.web}")

      view |> form("#resource-owner-form", owner: %{team: team.id}) |> render_change()

      assert has_element?(view, "#resource-owner", "Set by a person")
      assert Inventory.get_resource!(context.admin, context.web.id).owner_team_id == team.id

      view |> form("#resource-owner-form", owner: %{team: ""}) |> render_change()
      assert Inventory.get_resource!(context.admin, context.web.id).owner_team_id == nil
    end

    test "admins without teams are pointed at Settings", context do
      {:ok, view, _html} = live(context.admin_conn, ~p"/inventory/#{context.web}")

      assert has_element?(view, "#resource-owner-no-teams a[href='/settings/teams']")
      refute has_element?(view, "#resource-owner-form")
    end

    test "members request an owner instead of setting it", context do
      {:ok, team} = Teams.create_team(context.admin, %{"name" => "Platform"})
      {:ok, view, _html} = live(context.member_conn, ~p"/inventory/#{context.web}")

      refute has_element?(view, "#resource-owner-form")
      assert has_element?(view, "#resource-owner-name", "No owner")

      view
      |> form("#resource-owner-request-form", request: %{value: team.id, reason: "We run it"})
      |> render_submit()

      assert has_element?(view, "#resource-owner-request", "Platform")
      assert [%{kind: "owner"}] = elem(Requests.list_requests(context.admin), 0)
    end
  end

  describe "Inventory" do
    test "shows owners, filters by owner, and sets owners in bulk", context do
      {:ok, team} = Teams.create_team(context.admin, %{"name" => "Platform"})
      {:ok, _web} = Teams.set_owner(context.admin, context.web, team.id)

      {:ok, view, _html} = live(context.admin_conn, ~p"/inventory")
      assert has_element?(view, "#resources-#{context.web.id} [data-owner]", "Platform")
      assert has_element?(view, "#resources-#{context.db.id}", "Unowned")

      {:ok, view, _html} = live(context.admin_conn, ~p"/inventory?owner=none")
      assert has_element?(view, "#chip-owner", "nobody")
      assert has_element?(view, "#resources-#{context.db.id}")
      refute has_element?(view, "#resources-#{context.web.id}")

      {:ok, view, _html} = live(context.admin_conn, ~p"/inventory?sel=#{context.db.id}")
      view |> form("#bulk-owner-form", team: team.id) |> render_submit()

      assert Inventory.get_resource!(context.admin, context.db.id).owner_team_id == team.id
    end

    test "a malformed owner in the URL is ignored", context do
      {:ok, view, _html} = live(context.admin_conn, ~p"/inventory?owner=not-a-uuid")
      refute has_element?(view, "#chip-owner")
      assert has_element?(view, "#resources-#{context.web.id}")
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
