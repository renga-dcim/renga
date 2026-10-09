defmodule Renga.IPAMPrefixWritesTest do
  @moduledoc """
  Prefix writes (RFD 4, Phase 1): owners and admins only, re-checked in the
  database; one prefix per CIDR in each routing table; and a change event so
  every new prefix shows in Activity.
  """
  use Renga.DataCase, async: true

  import Renga.AccountsFixtures
  import Renga.InventoryFixtures
  import Renga.TopologyFixtures

  alias Renga.Accounts
  alias Renga.Inventory
  alias Renga.Inventory.Prefix
  alias Renga.Inventory.Resource
  alias Renga.IPAM
  alias Renga.Topology

  setup do
    organization = organization_fixture()
    %{organization: organization, admin: scope_for(organization, "admin")}
  end

  test "owners and admins create a prefix with its envelope and an Activity event", context do
    owner = scope_for(context.organization, "owner")

    assert {:ok, %Prefix{} = prefix} =
             IPAM.create_prefix(context.admin, %{prefix: "10.0.0.0/24", description: "Users"})

    assert prefix.status == "active"
    assert prefix.resource.kind == "prefix"
    assert prefix.resource.display_name == "10.0.0.0/24"
    assert "prefix-" <> _uuid = prefix.resource.name

    assert {:ok, blue} = IPAM.create_prefix(owner, %{prefix: "10.0.0.0/24", vrf: "blue"})
    assert blue.resource.display_name == "10.0.0.0/24 (blue)"

    assert [event] =
             context.admin
             |> Inventory.list_activity()
             |> Enum.filter(&(&1.resource_id == prefix.resource_id))

    assert %{kind: "created", field: "prefix", new_value: %{"value" => "10.0.0.0/24"}} = event
    assert event.actor_user_id == context.admin.user.id
    assert RengaWeb.ChangeDescription.describe(event) == "Created prefix 10.0.0.0/24"
  end

  test "members, viewers, and revoked admins cannot create prefixes", context do
    for role <- ~w(member viewer) do
      assert {:error, :forbidden} =
               IPAM.create_prefix(scope_for(context.organization, role), %{prefix: "10.0.0.0/24"})
    end

    # The scope still says admin; the database no longer does.
    revoked = scope_for(context.organization, "admin")
    membership = Repo.get!(Accounts.OrganizationMembership, revoked.membership_id)
    {:ok, _} = Accounts.update_organization_membership(membership, %{status: "disabled"})

    assert {:error, :forbidden} = IPAM.create_prefix(revoked, %{prefix: "10.0.0.0/24"})
    assert prefix_resources(context.organization) == 0
  end

  test "a routing table holds one prefix per CIDR", context do
    assert {:ok, _} = IPAM.create_prefix(context.admin, %{prefix: "10.0.0.0/24"})

    assert {:error, changeset} = IPAM.create_prefix(context.admin, %{prefix: "10.0.0.0/24"})
    assert %{prefix: ["already exists in this routing table"]} = errors_on(changeset)

    # Containment is hierarchy, and another table is another namespace.
    assert {:ok, _} = IPAM.create_prefix(context.admin, %{prefix: "10.0.0.0/25"})
    assert {:ok, _} = IPAM.create_prefix(context.admin, %{prefix: "10.0.0.0/24", vrf: "blue"})

    assert {:error, changeset} =
             IPAM.create_prefix(context.admin, %{prefix: "10.0.0.0/24", vrf: "blue"})

    assert %{prefix: ["already exists in this routing table"]} = errors_on(changeset)

    # Another organization's table is separate too.
    other = scope_for(organization_fixture(), "admin")
    assert {:ok, _} = IPAM.create_prefix(other, %{prefix: "10.0.0.0/24"})

    # A rejected prefix leaves no envelope behind.
    assert prefix_resources(context.organization) == 3
  end

  test "prefixes may be containers, and unknown statuses are refused", context do
    assert {:ok, %{status: "container"}} =
             IPAM.create_prefix(context.admin, %{prefix: "10.0.0.0/8", status: "container"})

    assert {:error, changeset} =
             IPAM.create_prefix(context.admin, %{prefix: "10.1.0.0/16", status: "planned"})

    assert %{status: ["is invalid"]} = errors_on(changeset)

    assert {:error, changeset} = IPAM.create_prefix(context.admin, %{prefix: "10.0.0.1/8"})
    assert %{prefix: ["is invalid"]} = errors_on(changeset)
  end

  test "prefix envelopes are created and changed only under the IPAM rules", context do
    assert {:error, changeset} =
             Inventory.create_resource(context.admin, %{kind: "prefix", name: "loose"})

    assert %{kind: ["must be created through the IPAM context"]} = errors_on(changeset)

    {:ok, prefix} = IPAM.create_prefix(context.admin, %{prefix: "10.0.0.0/24"})
    member = scope_for(context.organization, "member")

    assert {:error, :forbidden} =
             Inventory.update_resource(member, prefix.resource, %{lifecycle_state: "retired"})
  end

  test "an edit records each changed field and follows a new CIDR in the name", context do
    {:ok, prefix} = IPAM.create_prefix(context.admin, %{prefix: "10.0.0.0/24"})
    {:ok, _} = IPAM.create_prefix(context.admin, %{prefix: "10.0.1.0/24"})

    assert {:ok, updated} =
             IPAM.update_prefix(context.admin, prefix, %{
               prefix: "10.0.2.0/24",
               vrf: "blue",
               status: "reserved",
               description: "Lab"
             })

    assert updated.resource.display_name == "10.0.2.0/24 (blue)"
    assert updated.resource.name == prefix.resource.name

    events =
      context.admin
      |> Inventory.list_activity()
      |> Enum.filter(&(&1.resource_id == prefix.resource_id and &1.kind == "updated"))
      |> Map.new(&{&1.field, {&1.old_value["value"], &1.new_value["value"]}})

    assert events == %{
             "prefix" => {"10.0.0.0/24", "10.0.2.0/24"},
             "routing_table" => {"Global", "blue"},
             "status" => {"active", "reserved"},
             "description" => {nil, "Lab"}
           }

    # Editing into a CIDR the table already holds is refused like creating it.
    assert {:error, changeset} =
             IPAM.update_prefix(context.admin, updated, %{prefix: "10.0.1.0/24", vrf: nil})

    assert %{prefix: ["already exists in this routing table"]} = errors_on(changeset)

    member = scope_for(context.organization, "member")
    assert {:error, :forbidden} = IPAM.update_prefix(member, updated, %{status: "deprecated"})
    assert Repo.get!(Prefix, prefix.id).status == "reserved"
  end

  test "deleting a prefix keeps its addresses and its history", context do
    {:ok, prefix} = IPAM.create_prefix(context.admin, %{prefix: "192.0.2.0/24"})

    {_host, ports} =
      device_fixture(context.admin, "server", "keep", ~w(eth0))

    address = address_fixture(context.admin, ports["eth0"], "192.0.2.5")
    group = vlan_group_fixture(context.admin, "delete")
    vlan = vlan_fixture(context.admin, group, 10, "users")
    {:ok, _} = Topology.attach_prefix_vlan(context.admin, prefix.id, vlan.id)

    member = scope_for(context.organization, "member")
    assert {:error, :forbidden} = IPAM.delete_prefix(member, prefix)

    assert {:ok, _} = IPAM.delete_prefix(context.admin, prefix)

    refute Repo.get(Prefix, prefix.id)
    refute Repo.get(Resource, prefix.resource_id)
    assert Topology.list_vlan_prefixes(context.admin, vlan.id) == []
    assert Repo.get!(Inventory.Address, address.id)

    assert %{resource_id: nil} =
             event =
             context.admin
             |> Inventory.list_activity()
             |> Enum.find(&(&1.kind == "deleted"))

    assert RengaWeb.ChangeDescription.describe(event) == "Deleted prefix 192.0.2.0/24"

    # The CIDR is free to plan again.
    assert {:ok, _} = IPAM.create_prefix(context.admin, %{prefix: "192.0.2.0/24"})
  end

  defp scope_for(organization, role) do
    user = user_fixture()
    organization_membership_fixture(user, organization, %{role: role})
    Accounts.scope_for_user(user, organization.id)
  end

  defp prefix_resources(organization) do
    Resource
    |> where([resource], resource.organization_id == ^organization.id)
    |> where([resource], resource.kind == "prefix")
    |> Repo.aggregate(:count)
  end
end
