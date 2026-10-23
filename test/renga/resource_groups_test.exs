defmodule Renga.ResourceGroupsTest do
  use Renga.DataCase, async: true

  import Renga.InventoryFixtures
  import Renga.JobsFixtures, only: [member_scope: 2]

  alias Renga.Accounts.Scope
  alias Renga.Assignments
  alias Renga.Inventory
  alias Renga.Inventory.ChangeEvent
  alias Renga.Repo
  alias Renga.ResourceGroups
  alias Renga.ResourceGroups.Group
  alias Renga.ResourceGroups.Member
  alias Renga.ResourceGroups.Membership
  alias Renga.Roles

  setup do
    organization = organization_fixture()
    admin = member_scope(organization, "admin")
    member = member_scope(organization, "member")
    viewer = member_scope(organization, "viewer")

    {:ok, web} = Inventory.create_resource(admin, %{kind: "server", name: "web-01"})
    {:ok, db} = Inventory.create_resource(admin, %{kind: "server", name: "db-01"})

    {:ok, environment} =
      ResourceGroups.create_group_set(admin, %{"name" => "Environment", "exclusive" => true})

    {:ok, production} =
      ResourceGroups.create_group(admin, %{
        "name" => "Production",
        "group_set_id" => environment.id
      })

    {:ok, staging} =
      ResourceGroups.create_group(admin, %{"name" => "Staging", "group_set_id" => environment.id})

    %{
      organization: organization,
      admin: admin,
      member: member,
      viewer: viewer,
      web: web,
      db: db,
      environment: environment,
      production: production,
      staging: staging
    }
  end

  describe "groups and sets" do
    test "managers define groups and sets with names unique per organization", context do
      assert {:ok, lab} = ResourceGroups.create_group(context.admin, %{"name" => " Lab "})
      assert lab.name == "Lab"
      assert lab.group_set_id == nil

      assert {:error, changeset} = ResourceGroups.create_group(context.admin, %{"name" => "lab"})
      assert "is already a group in this organization" in errors_on(changeset).name

      assert {:error, changeset} =
               ResourceGroups.create_group_set(context.admin, %{"name" => "environment"})

      assert "is already a group set in this organization" in errors_on(changeset).name

      assert ~w(Lab Production Staging) ==
               context.admin |> ResourceGroups.list_groups() |> Enum.map(& &1.name)
    end

    test "a group's set must be in the same organization", context do
      other = organization_fixture() |> member_scope("owner")
      {:ok, foreign} = ResourceGroups.create_group_set(other, %{"name" => "Customer"})

      assert {:error, changeset} =
               ResourceGroups.create_group(context.admin, %{
                 "name" => "Acme",
                 "group_set_id" => foreign.id
               })

      assert "does not exist" in errors_on(changeset).group_set
    end

    test "members and viewers cannot define groups", context do
      for scope <- [context.member, context.viewer] do
        assert {:error, :forbidden} = ResourceGroups.create_group(scope, %{"name" => "Lab"})
        assert {:error, :forbidden} = ResourceGroups.create_group_set(scope, %{"name" => "Tier"})

        assert {:error, :forbidden} =
                 ResourceGroups.update_group(scope, context.staging, %{"name" => "QA"})

        refute ResourceGroups.can_manage?(scope)
      end

      assert ResourceGroups.can_manage?(context.admin)
    end

    test "creating, renaming, and deleting groups and sets is recorded", context do
      {:ok, renamed} =
        ResourceGroups.update_group(context.admin, context.staging, %{"name" => "QA"})

      {:ok, _set} =
        ResourceGroups.update_group_set(context.admin, context.environment, %{"name" => "Env"})

      {:ok, _deleted} = ResourceGroups.delete_group(context.admin, renamed)

      kinds = context.admin |> group_events() |> Enum.map(& &1.kind)

      assert Enum.take(kinds, 3) == ~w(group_deleted group_set_updated group_updated)
      assert "group_set_created" in kinds
      assert Enum.count(kinds, &(&1 == "group_created")) == 2
    end

    test "deleting a populated group also needs inventory.edit", context do
      {:ok, group_manager} =
        Roles.create_role(context.admin, %{
          "name" => "Group manager",
          "permissions" => ["groups.manage"]
        })

      {:ok, _assignment} =
        Assignments.assign(context.admin, context.viewer.membership_id, %{
          "role" => group_manager.id
        })

      {:ok, 1} =
        ResourceGroups.add_members(context.admin, context.staging, [context.web.id])

      event_count = Repo.aggregate(ChangeEvent, :count)

      assert {:error, :forbidden} =
               ResourceGroups.delete_group(context.viewer, context.staging)

      assert Repo.get!(Group, context.staging.id)
      assert Repo.aggregate(Member, :count) == 1
      assert length(effective(context.web)) == 2
      assert Repo.aggregate(ChangeEvent, :count) == event_count

      {:ok, empty} = ResourceGroups.create_group(context.admin, %{"name" => "Empty"})
      assert {:ok, _deleted} = ResourceGroups.delete_group(context.viewer, empty)
    end
  end

  describe "membership" do
    test "people with inventory.edit add and remove members in both views", context do
      assert {:ok, 2} =
               ResourceGroups.add_members(context.admin, context.staging, [
                 context.web.id,
                 context.db.id
               ])

      # Adding again changes nothing.
      assert {:ok, 0} =
               ResourceGroups.add_members(context.admin, context.staging, [context.web.id])

      assert effective(context.web) == [
               {"inventory", context.staging.id, context.environment.id},
               {"trusted", context.staging.id, context.environment.id}
             ]

      assert [%{group: %{name: "Staging"}, direct: true}] =
               ResourceGroups.list_resource_groups(context.admin, context.web.id)

      assert {:ok, 1} =
               ResourceGroups.remove_members(context.admin, context.staging, [context.web.id],
                 reason: "rebuilt as prod"
               )

      assert effective(context.web) == []
      assert length(effective(context.db)) == 2

      assert [removed, added | _] = Inventory.list_change_events(context.admin, context.web.id)
      assert removed.kind == "group_member_removed"

      assert removed.metadata == %{
               "group_id" => context.staging.id,
               "reason" => "rebuilt as prod"
             }

      assert removed.actor_user_id == context.admin.user.id
      assert added.kind == "group_member_added"
      assert added.new_value["name"] == "Staging"
    end

    test "changing membership needs inventory.edit", context do
      for scope <- [context.member, context.viewer] do
        assert {:error, :forbidden} =
                 ResourceGroups.add_members(scope, context.staging, [context.web.id])

        refute ResourceGroups.can_change_membership?(scope)
      end

      assert Repo.all(Member) == []
    end

    test "no machine principal can change direct membership", context do
      for principal <- Renga.Authorization.machine_principals() do
        machine = %Scope{
          organization: context.organization,
          organization_id: context.organization.id,
          roles: [principal]
        }

        assert {:error, :forbidden} =
                 ResourceGroups.add_members(machine, context.staging, [context.web.id])

        assert {:error, :forbidden} =
                 ResourceGroups.move_member(machine, context.web.id, context.staging)
      end

      assert Repo.all(Member) == []
    end

    test "a bulk change naming any unknown resource changes nothing", context do
      other = organization_fixture() |> member_scope("owner")
      {:ok, foreign} = Inventory.create_resource(other, %{kind: "server", name: "elsewhere"})

      for bogus <- [foreign.id, Ecto.UUID.generate(), "not-a-uuid"] do
        assert {:error, :not_found} =
                 ResourceGroups.add_members(context.admin, context.staging, [
                   context.web.id,
                   bogus
                 ])
      end

      assert Repo.all(Member) == []
      assert Repo.all(Membership) == []
    end

    test "a group in another organization is not found", context do
      other = organization_fixture() |> member_scope("owner")
      {:ok, theirs} = ResourceGroups.create_group(other, %{"name" => "Theirs"})

      assert {:error, :not_found} =
               ResourceGroups.add_members(context.admin, theirs, [context.web.id])

      assert ResourceGroups.get_group(context.admin, theirs.id) == nil
    end
  end

  describe "exclusive sets" do
    test "a resource cannot join two groups of an exclusive set", context do
      {:ok, 1} = ResourceGroups.add_members(context.admin, context.production, [context.web.id])

      assert {:error, {:exclusive_conflict, [conflict]}} =
               ResourceGroups.add_members(context.admin, context.staging, [
                 context.db.id,
                 context.web.id
               ])

      assert conflict == %{
               resource_id: context.web.id,
               resource: "web-01",
               group_set: "Environment",
               groups: ["Production", "Staging"]
             }

      # The whole bulk change was refused, db-01 included, with no Activity.
      assert effective(context.db) == []

      refute Enum.any?(
               Inventory.list_change_events(context.admin, context.db.id),
               &(&1.kind =~ "group")
             )
    end

    test "moving within a set is one change", context do
      {:ok, 1} = ResourceGroups.add_members(context.admin, context.production, [context.web.id])

      assert {:ok, :moved} =
               ResourceGroups.move_member(context.admin, context.web.id, context.staging,
                 reason: "demoted"
               )

      assert {:ok, :unchanged} =
               ResourceGroups.move_member(context.admin, context.web.id, context.staging)

      assert effective(context.web) == [
               {"inventory", context.staging.id, context.environment.id},
               {"trusted", context.staging.id, context.environment.id}
             ]

      move_events =
        context.admin
        |> Inventory.list_change_events(context.web.id)
        |> Enum.take(2)
        |> Enum.map(& &1.kind)

      assert Enum.sort(move_events) == ~w(group_member_added group_member_removed)
    end

    test "moving needs a group in a set", context do
      {:ok, lab} = ResourceGroups.create_group(context.admin, %{"name" => "Lab"})

      assert {:error, :not_in_set} =
               ResourceGroups.move_member(context.admin, context.web.id, lab)
    end

    test "a set cannot become exclusive while a resource is in two of its groups", context do
      {:ok, customer} = ResourceGroups.create_group_set(context.admin, %{"name" => "Customer"})
      {:ok, acme} = group_in(context.admin, "Acme", customer)
      {:ok, globex} = group_in(context.admin, "Globex", customer)

      {:ok, 2} = ResourceGroups.add_members(context.admin, acme, [context.web.id, context.db.id])
      {:ok, 1} = ResourceGroups.add_members(context.admin, globex, [context.web.id])

      assert effective(context.web) |> Enum.map(&elem(&1, 2)) |> Enum.uniq() == [nil]

      assert {:error, {:exclusive_conflict, [%{resource: "web-01", groups: ["Acme", "Globex"]}]}} =
               ResourceGroups.update_group_set(context.admin, customer, %{"exclusive" => true})

      {:ok, 1} = ResourceGroups.remove_members(context.admin, globex, [context.web.id])

      assert {:ok, %{exclusive: true}} =
               ResourceGroups.update_group_set(context.admin, customer, %{"exclusive" => true})

      assert effective(context.web) |> Enum.map(&elem(&1, 2)) |> Enum.uniq() == [customer.id]

      # Turning exclusivity off again releases the constraint.
      {:ok, _set} =
        ResourceGroups.update_group_set(context.admin, customer, %{"exclusive" => false})

      assert {:ok, 1} = ResourceGroups.add_members(context.admin, globex, [context.web.id])
    end

    test "a group cannot move into an exclusive set its members conflict with", context do
      {:ok, legacy} = ResourceGroups.create_group(context.admin, %{"name" => "Legacy prod"})
      {:ok, 1} = ResourceGroups.add_members(context.admin, context.production, [context.web.id])

      {:ok, 2} =
        ResourceGroups.add_members(context.admin, legacy, [context.web.id, context.db.id])

      assert {:error, {:exclusive_conflict, [%{resource: "web-01"}]}} =
               ResourceGroups.update_group(context.admin, legacy, %{
                 "group_set_id" => context.environment.id
               })

      assert Repo.reload!(legacy).group_set_id == nil
    end

    test "the database refuses a second exclusive membership", context do
      {:ok, 1} = ResourceGroups.add_members(context.admin, context.production, [context.web.id])

      assert_raise Postgrex.Error, ~r/resource_group_memberships_exclusive_index/, fn ->
        Repo.insert_all(Membership, [
          %{
            organization_id: context.organization.id,
            resource_id: context.web.id,
            view: "trusted",
            group_id: context.staging.id,
            group_set_id: context.environment.id
          }
        ])
      end
    end

    test "deleting a set keeps its groups and lifts exclusivity", context do
      {:ok, 1} = ResourceGroups.add_members(context.admin, context.production, [context.web.id])
      {:ok, _set} = ResourceGroups.delete_group_set(context.admin, context.environment)

      assert Repo.reload!(context.production).group_set_id == nil
      assert effective(context.web) |> Enum.map(&elem(&1, 2)) |> Enum.uniq() == [nil]

      assert {:ok, 1} =
               ResourceGroups.add_members(context.admin, context.staging, [context.web.id])
    end
  end

  test "deleting a group removes its members, each recorded on the resource", context do
    {:ok, 2} =
      ResourceGroups.add_members(context.admin, context.staging, [context.web.id, context.db.id])

    assert {:ok, _group} = ResourceGroups.delete_group(context.admin, context.staging)

    for resource <- [context.web, context.db] do
      assert effective(resource) == []

      assert [%{kind: "group_member_removed", metadata: %{"reason" => "group_deleted"}} | _] =
               Inventory.list_change_events(context.admin, resource.id)
    end

    assert [%{kind: "group_deleted", metadata: %{"members" => 2}} | _] =
             group_events(context.admin)
  end

  describe "visibility" do
    test "only managers see empty groups; readers see groups with members", context do
      {:ok, 1} = ResourceGroups.add_members(context.admin, context.staging, [context.web.id])

      assert ~w(Production Staging) ==
               context.admin |> ResourceGroups.list_groups() |> Enum.map(& &1.name)

      for scope <- [context.member, context.viewer] do
        assert [%{name: "Staging", member_count: 1}] = ResourceGroups.list_groups(scope)
        assert ResourceGroups.get_group(scope, context.production.id) == nil
        assert [%{name: "Environment"}] = ResourceGroups.list_group_sets(scope)
      end
    end

    test "a set with no visible group is hidden from non-managers", context do
      {:ok, _customer} = ResourceGroups.create_group_set(context.admin, %{"name" => "Customer"})

      assert ResourceGroups.list_group_sets(context.viewer) == []
      assert length(ResourceGroups.list_group_sets(context.admin)) == 2
    end
  end

  defp group_in(scope, name, set),
    do: ResourceGroups.create_group(scope, %{"name" => name, "group_set_id" => set.id})

  defp effective(resource) do
    Membership
    |> where([membership], membership.resource_id == ^resource.id)
    |> order_by([membership], asc: membership.view, asc: membership.group_id)
    |> select([membership], {membership.view, membership.group_id, membership.group_set_id})
    |> Repo.all()
  end

  defp group_events(%Scope{organization_id: organization_id}) do
    Renga.Inventory.ChangeEvent
    |> where([event], event.organization_id == ^organization_id)
    |> where([event], is_nil(event.resource_id))
    |> where([event], like(event.kind, "group_%"))
    |> order_by([event], desc: event.occurred_at, desc: event.inserted_at)
    |> Repo.all()
  end
end
