defmodule Renga.TeamsTest do
  use Renga.DataCase, async: true

  import Renga.AccountsFixtures
  import Renga.InventoryFixtures

  alias Renga.Inventory
  alias Renga.Inventory.Changes
  alias Renga.Requests
  alias Renga.Teams

  setup do
    organization = organization_fixture()
    admin = member_scope(organization, "admin")
    member = member_scope(organization, "member")

    {:ok, web} = Inventory.create_resource(admin, %{kind: "server", name: "web-01"})
    {:ok, db} = Inventory.create_resource(admin, %{kind: "server", name: "db-01"})

    %{organization: organization, admin: admin, member: member, web: web, db: db}
  end

  describe "teams" do
    test "owners and admins create, rename, and list teams with what they own", context do
      assert {:ok, platform} = Teams.create_team(context.admin, %{"name" => " Platform "})
      assert platform.name == "Platform"

      assert {:error, changeset} = Teams.create_team(context.admin, %{"name" => "platform"})
      assert "is already a team in this organization" in errors_on(changeset).name

      {:ok, _web} = Teams.set_owner(context.admin, context.web, platform.id)
      {:ok, renamed} = Teams.update_team(context.admin, platform, %{"name" => "Platform Eng"})

      assert [%{name: "Platform Eng", resource_count: 1}] = Teams.list_teams(context.admin)
      assert renamed.id == platform.id
    end

    test "members and viewers cannot manage teams", context do
      viewer = member_scope(context.organization, "viewer")

      assert {:error, :forbidden} = Teams.create_team(context.member, %{"name" => "Ops"})
      assert {:error, :forbidden} = Teams.create_team(viewer, %{"name" => "Ops"})
      refute Teams.can_manage?(context.member)
    end

    test "deleting a team leaves its resources unowned, each recorded", context do
      {:ok, team} = Teams.create_team(context.admin, %{"name" => "Storage"})
      {:ok, 2} = Teams.set_owners(context.admin, [context.web.id, context.db.id], team.id)

      assert {:ok, _team} = Teams.delete_team(context.admin, team)

      for resource <- [context.web, context.db] do
        reloaded = Inventory.get_resource!(context.admin, resource.id)
        assert {reloaded.owner_team_id, reloaded.owner_source} == {nil, nil}

        assert [%{kind: "owner_changed", new_value: nil, old_value: %{"name" => "Storage"}} | _] =
                 owner_events(context.admin, resource.id)
      end
    end
  end

  describe "owners" do
    test "setting an owner records the person, a revision, and Activity", context do
      {:ok, team} = Teams.create_team(context.admin, %{"name" => "Platform"})
      :ok = Changes.subscribe(context.admin)

      assert {:ok, resource} = Teams.set_owner(context.admin, context.web, team.id)
      assert_receive {:inventory_changed, _organization_id}

      assert {resource.owner_team_id, resource.owner_source} == {team.id, "person"}
      assert resource.resource_version > context.web.resource_version

      assert [%{new_value: %{"name" => "Platform"}, actor_user_id: actor}] =
               owner_events(context.admin, context.web.id)

      assert actor == context.admin.user.id

      # Setting the same owner again changes nothing and records nothing.
      assert {:ok, 0} = Teams.set_owners(context.admin, [context.web.id], team.id)
      assert length(owner_events(context.admin, context.web.id)) == 1
    end

    test "bulk owners ignore foreign or malformed ids and reject foreign teams", context do
      {:ok, team} = Teams.create_team(context.admin, %{"name" => "Platform"})
      other = member_scope(organization_fixture(), "admin")
      {:ok, foreign_team} = Teams.create_team(other, %{"name" => "Theirs"})
      {:ok, foreign} = Inventory.create_resource(other, %{kind: "server", name: "x"})

      assert {:ok, 1} =
               Teams.set_owners(context.admin, [context.web.id, foreign.id, "nope"], team.id)

      assert Inventory.get_resource!(other, foreign.id).owner_team_id == nil

      assert {:error, :invalid_team} =
               Teams.set_owners(context.admin, [context.db.id], foreign_team.id)
    end

    test "only owners and admins set owners directly", context do
      {:ok, team} = Teams.create_team(context.admin, %{"name" => "Platform"})
      assert {:error, :forbidden} = Teams.set_owner(context.member, context.web, team.id)
    end

    test "inventory filters by owner, including unowned", context do
      {:ok, team} = Teams.create_team(context.admin, %{"name" => "Platform"})
      {:ok, _web} = Teams.set_owner(context.admin, context.web, team.id)

      %{entries: [owned]} = Inventory.list_operational_resources(context.admin, owner: team.id)
      assert owned.id == context.web.id
      assert owned.owner_team.name == "Platform"

      %{entries: [unowned]} = Inventory.list_operational_resources(context.admin, owner: :none)
      assert unowned.id == context.db.id
    end
  end

  describe "owner requests" do
    test "members request an owner, approval sets it as the approver", context do
      {:ok, team} = Teams.create_team(context.admin, %{"name" => "Platform"})

      assert {:ok, request} =
               Requests.request_owner(context.member, context.web, %{
                 "value" => team.id,
                 "reason" => "Platform runs this host"
               })

      assert request.after_value == %{"value" => "Platform", "team_id" => team.id}
      assert request.before_value == nil

      assert {:ok, 1} = Requests.approve(context.admin, request)

      resource = Inventory.get_resource!(context.admin, context.web.id)
      assert {resource.owner_team_id, resource.owner_source} == {team.id, "person"}

      assert [%{actor_user_id: actor}] = owner_events(context.admin, context.web.id)
      assert actor == context.admin.user.id
    end

    test "a request must name a team in the organization and change the owner", context do
      {:ok, team} = Teams.create_team(context.admin, %{"name" => "Platform"})
      foreign = member_scope(organization_fixture(), "admin")
      {:ok, foreign_team} = Teams.create_team(foreign, %{"name" => "Theirs"})

      assert {:error, changeset} =
               Requests.request_owner(context.member, context.web, %{
                 "value" => foreign_team.id,
                 "reason" => "x"
               })

      assert "choose a team" in errors_on(changeset).after_value

      {:ok, _web} = Teams.set_owner(context.admin, context.web, team.id)
      web = Inventory.get_resource!(context.admin, context.web.id)

      assert {:error, changeset} =
               Requests.request_owner(context.member, web, %{"value" => team.id, "reason" => "x"})

      assert "is already the current value" in errors_on(changeset).after_value
    end
  end

  defp owner_events(scope, resource_id) do
    scope
    |> Inventory.list_change_events(resource_id)
    |> Enum.filter(&(&1.kind == "owner_changed"))
  end

  defp member_scope(organization, role) do
    user = user_fixture()
    organization_membership_fixture(user, organization, %{role: role})
    Renga.Accounts.scope_for_user(user, organization.id)
  end
end
