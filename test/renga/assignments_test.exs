defmodule Renga.AssignmentsTest do
  use Renga.DataCase, async: true

  import Renga.InventoryFixtures
  import Renga.JobsFixtures, only: [member_scope: 2]

  alias Renga.Accounts
  alias Renga.Assignments
  alias Renga.Authorization
  alias Renga.Findings
  alias Renga.Inventory
  alias Renga.Members
  alias Renga.Repo
  alias Renga.Roles
  alias Renga.Roles.Assignment

  setup do
    organization = organization_fixture()

    %{
      owner: member_scope(organization, "owner"),
      admin: member_scope(organization, "admin"),
      member: member_scope(organization, "member"),
      viewer: member_scope(organization, "viewer")
    }
  end

  defp role(scope, name, permissions) do
    {:ok, role} = Roles.create_role(scope, %{"name" => name, "permissions" => permissions})
    role
  end

  defp assign(actor, target, role, attrs \\ %{}),
    do: Assignments.assign(actor, target.membership_id, Map.put(attrs, "role", role))

  # The scope a fresh request would build, so it reflects current assignments.
  defp reload(scope), do: Accounts.scope_for_user(scope.user, scope.organization_id)

  defp authorized?(scope, permission) do
    match?({:ok, :ok}, Repo.transaction(fn -> Authorization.authorize!(scope, permission) end))
  end

  test "a custom role adds its permissions to the base role", context do
    network = role(context.admin, "Network", ~w(ipam.edit findings.act))
    refute authorized?(context.viewer, "ipam.edit")

    assert {:ok, assignment} = assign(context.admin, context.viewer, network.id)
    assert Assignment.role_name(assignment) == "Network"

    # The transaction check reads assignments, even through a stale scope.
    assert authorized?(context.viewer, "ipam.edit")
    refute authorized?(context.viewer, "dcim.edit")

    viewer = reload(context.viewer)
    assert viewer.permissions == ~w(findings.act ipam.edit)
    assert Authorization.allowed?(viewer, "ipam.edit")
    refute Authorization.allowed?(viewer, "dcim.edit")

    # People pickers count assignment holders.
    assert viewer.user.id in Enum.map(Findings.assignable_users(context.owner), & &1.id)
  end

  test "a built-in role assignment raises the grant ceiling", context do
    refute authorized?(context.member, "members.manage")
    assert {:ok, _} = assign(context.owner, context.member, "admin")

    member = reload(context.member)
    assert member.roles == ~w(member admin)
    assert authorized?(member, "members.manage")
    assert Authorization.current_roles!(member) == ~w(member admin)
    assert {:ok, _} = Members.change_role(member, context.viewer.membership_id, "member")
  end

  test "expired and disabled assignments grant nothing", context do
    {:ok, assignment} = assign(context.admin, context.viewer, "member")
    assert authorized?(context.viewer, "findings.act")

    past = DateTime.add(Renga.Time.utc_now_ms(), -1, :minute)
    Repo.update_all(where(Assignment, id: ^assignment.id), set: [valid_until: past])

    refute authorized?(context.viewer, "findings.act")
    assert reload(context.viewer).roles == ["viewer"]

    # Once expired, the role can be given again.
    assert {:ok, _} = assign(context.admin, context.viewer, "member")
    {:ok, _} = Members.disable_member(context.owner, context.viewer.membership_id)
    refute authorized?(context.viewer, "findings.act")
  end

  test "validates the role, deadline, and duplicates", context do
    assert {:error, %Ecto.Changeset{} = changeset} = assign(context.admin, context.viewer, "root")
    assert "choose a role" in errors_on(changeset).built_in_role

    past = DateTime.add(Renga.Time.utc_now_ms(), -1, :day) |> DateTime.to_iso8601()

    assert {:error, changeset} =
             assign(context.admin, context.viewer, "member", %{"valid_until" => past})

    assert "must be in the future" in errors_on(changeset).valid_until

    later = DateTime.add(Renga.Time.utc_now_ms(), 1, :day) |> DateTime.to_iso8601()

    assert {:ok, %{valid_until: %DateTime{}}} =
             assign(context.admin, context.viewer, "member", %{"valid_until" => later})

    assert {:error, :already_assigned} = assign(context.admin, context.viewer, "member")
  end

  test "admins cannot assign above their ceiling", context do
    exporter = role(context.owner, "Exporter", ~w(organization.export))

    assert {:error, :forbidden} = assign(context.admin, context.member, "owner")
    assert {:error, :forbidden} = assign(context.admin, context.member, exporter.id)
    assert {:error, :forbidden} = assign(context.member, context.viewer, "viewer")

    {:ok, assignment} = assign(context.owner, context.member, exporter.id)
    assert {:error, :forbidden} = Assignments.unassign(context.admin, assignment.id)

    %{built_in: built_in, custom: custom} = Assignments.assignable_roles(context.admin)
    assert built_in == ~w(admin member viewer)
    assert custom == []
    assert Assignments.assignable_roles(context.member) == %{built_in: [], custom: []}
  end

  test "roles from another organization cannot be assigned", context do
    stranger = member_scope(organization_fixture(), "owner")
    theirs = role(stranger, "Theirs", ~w(dcim.edit))

    assert {:error, %Ecto.Changeset{}} = assign(context.owner, context.viewer, theirs.id)

    assert {:error, :not_found} =
             Assignments.assign(context.owner, stranger.membership_id, %{"role" => "viewer"})
  end

  test "unassigning and deleting the role take access away, in Activity", context do
    racks = role(context.owner, "Racks", ~w(dcim.edit))
    {:ok, assignment} = assign(context.owner, context.viewer, racks.id, %{"reason" => "DC move"})
    {:ok, _} = assign(context.owner, context.member, racks.id)

    assert Assignments.role_usage(context.owner) == %{
             racks.id => %{people: 2, assignments: 2}
           }

    assert {:ok, _} = Assignments.unassign(context.owner, assignment.id, reason: "Done")
    refute authorized?(context.viewer, "dcim.edit")
    assert authorized?(context.member, "dcim.edit")

    {:ok, _} = Roles.delete_role(context.owner, racks)
    refute authorized?(context.member, "dcim.edit")
    assert Assignments.list_assignments(context.owner) == []

    [unassigned, assigned | _] =
      context.owner
      |> Inventory.list_activity()
      |> Enum.filter(&(&1.kind in ~w(role_assigned role_unassigned)))

    assert unassigned.kind == "role_unassigned"
    assert unassigned.metadata["reason"] == "Done"
    assert assigned.kind == "role_assigned"
  end
end
