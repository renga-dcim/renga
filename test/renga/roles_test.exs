defmodule Renga.RolesTest do
  use Renga.DataCase, async: true

  import Renga.InventoryFixtures
  import Renga.JobsFixtures, only: [member_scope: 2]

  alias Renga.Inventory
  alias Renga.Members
  alias Renga.Roles

  @network ~w(inventory.reconcile findings.act ipam.edit topology.edit)

  setup do
    organization = organization_fixture()

    %{
      owner: member_scope(organization, "owner"),
      admin: member_scope(organization, "admin"),
      member: member_scope(organization, "member")
    }
  end

  defp attrs(name, permissions), do: %{"name" => name, "permissions" => permissions}

  test "admins define, change, and delete roles, each in Activity", context do
    assert {:ok, role} = Roles.create_role(context.admin, attrs("Network engineer", @network))
    assert role.permissions == Enum.sort(@network)
    assert [%{name: "Network engineer"}] = Roles.list_roles(context.member)

    assert {:ok, role} =
             Roles.update_role(context.admin, role, attrs("Network", ["topology.edit"]))

    assert role.permissions == ["topology.edit"]
    assert {:ok, _} = Roles.delete_role(context.admin, role)
    assert Roles.list_roles(context.admin) == []

    kinds = context.owner |> Inventory.list_activity() |> Enum.map(& &1.kind)
    assert kinds == ~w(role_deleted role_updated role_created)
  end

  test "validates names and permissions", context do
    assert {:error, changeset} = Roles.create_role(context.owner, attrs("Owner", ["dcim.edit"]))
    assert "is the name of a built-in role" in errors_on(changeset).name

    assert {:error, changeset} = Roles.create_role(context.owner, attrs("Empty", []))
    assert "choose at least one permission" in errors_on(changeset).permissions

    assert {:error, changeset} = Roles.create_role(context.owner, attrs("Bad", ["root.all"]))
    assert "has an unknown permission" in errors_on(changeset).permissions

    {:ok, _} = Roles.create_role(context.owner, attrs("Racks", ["dcim.edit"]))
    assert {:error, changeset} = Roles.create_role(context.owner, attrs("racks", ["dcim.edit"]))
    assert "is already a role in this organization" in errors_on(changeset).name
  end

  test "blank updates return errors without changing the role or Activity", context do
    {:ok, role} = Roles.create_role(context.owner, attrs("Network", ["topology.edit"]))
    activity_before = Inventory.list_activity(context.owner)

    for name <- ["", "   ", nil] do
      assert {:error, changeset} =
               Roles.update_role(context.owner, role, %{
                 "name" => name,
                 "permissions" => ["topology.edit"]
               })

      assert "can't be blank" in errors_on(changeset).name
    end

    assert {:error, changeset} =
             Roles.update_role(context.owner, role, %{
               "name" => "Network",
               "permissions" => nil
             })

    assert "choose at least one permission" in errors_on(changeset).permissions

    assert %{name: "Network", permissions: ["topology.edit"]} =
             Roles.get_role(context.owner, role.id)

    assert Inventory.list_activity(context.owner) == activity_before
  end

  test "custom roles never carry member or role management", context do
    for reserved <- ~w(members.manage roles.manage) do
      assert {:error, changeset} = Roles.create_role(context.owner, attrs("Admins", [reserved]))
      assert "can't include members.manage or roles.manage" in errors_on(changeset).permissions
    end
  end

  test "admins cannot grant the owner-only permissions, before or after", context do
    assert {:error, changeset} =
             Roles.create_role(context.admin, attrs("Exporter", ["organization.export"]))

    assert errors_on(changeset).permissions == [
             "includes organization.export, which you may not grant"
           ]

    {:ok, exporter} = Roles.create_role(context.owner, attrs("Exporter", ["organization.export"]))

    assert {:error, :forbidden} =
             Roles.update_role(context.admin, exporter, attrs("Exporter", ["dcim.edit"]))

    assert {:error, :forbidden} = Roles.delete_role(context.admin, exporter)
    refute "organization.manage" in Roles.grantable_permissions(context.admin)
    assert "organization.manage" in Roles.grantable_permissions(context.owner)
  end

  test "needs roles.manage, re-read in the transaction", context do
    assert {:error, :forbidden} = Roles.create_role(context.member, attrs("X", ["dcim.edit"]))
    assert Roles.grantable_permissions(context.member) == []

    {:ok, _} = Members.change_role(context.owner, context.admin.membership_id, "member")
    assert {:error, :forbidden} = Roles.create_role(context.admin, attrs("X", ["dcim.edit"]))
  end

  test "roles from another organization are invisible", context do
    stranger = member_scope(organization_fixture(), "owner")
    {:ok, role} = Roles.create_role(stranger, attrs("Theirs", ["dcim.edit"]))

    assert Roles.get_role(context.owner, role.id) == nil
    assert {:error, :not_found} = Roles.delete_role(context.owner, role)
  end
end
