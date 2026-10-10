defmodule Renga.IPAMAddressesTest do
  @moduledoc """
  Managed addresses beyond adoption (RFD 4, Phase 3): reservations by hand
  in any routing table, assignments that respect the address's role, edits
  with stale-edit protection, and the adopt, release, and re-adopt cycle of
  one canonical record.
  """
  use Renga.DataCase, async: true

  import Renga.AccountsFixtures
  import Renga.InventoryFixtures
  import Renga.TopologyFixtures

  alias Renga.Accounts
  alias Renga.Inventory
  alias Renga.Inventory.Resource
  alias Renga.IPAM
  alias Renga.IPAM.Cidr
  alias Renga.IPAM.IpAddress
  alias Renga.IPAM.IpAddressAssignment

  setup do
    organization = organization_fixture()
    admin = scope_for(organization, "admin")
    {host, ports} = device_fixture(admin, "server", "lb-01", ~w(eth0 eth1))
    {other_host, other_ports} = device_fixture(admin, "server", "lb-02", ~w(eth0))

    %{
      organization: organization,
      admin: admin,
      host: host,
      other_host: other_host,
      eth0: ports["eth0"],
      eth1: ports["eth1"],
      other_eth0: other_ports["eth0"]
    }
  end

  describe "reserving by hand" do
    test "reserves an address in any routing table, once per host", context do
      blue = vrf_fixture(context.admin, "blue")

      assert {:ok, %IpAddress{} = reserved} =
               IPAM.create_ip_address(context.admin, %{
                 address: "192.0.2.10/24",
                 dns_name: " gw.example.net ",
                 description: "Gateway"
               })

      assert %{allocation_state: "reserved", role: "ordinary", vrf_id: nil} = reserved
      assert reserved.dns_name == "gw.example.net"
      assert Cidr.format(reserved.address) == "192.0.2.10/24"
      assert reserved.assignments == []
      assert Repo.get!(Resource, reserved.resource_id).display_name == "192.0.2.10"

      # The same host is another address in a VRF...
      assert {:ok, in_blue} =
               IPAM.create_ip_address(context.admin, %{
                 address: "192.0.2.10/32",
                 vrf_id: blue.id,
                 allocation_state: "allocated"
               })

      assert Repo.get!(Resource, in_blue.resource_id).display_name == "192.0.2.10 (blue)"

      # ...but the same host again in one table, whatever its mask, is not.
      assert {:error, changeset} =
               IPAM.create_ip_address(context.admin, %{address: "192.0.2.10/32"})

      assert %{address: ["is already managed in this routing table"]} = errors_on(changeset)

      assert [%{kind: "created", field: "ip_address", new_value: %{"value" => "192.0.2.10"}}] =
               context.admin
               |> Inventory.list_activity()
               |> Enum.filter(&(&1.resource_id == reserved.resource_id))
    end

    test "an IPv6 address is managed, assigned, and identified by its host", context do
      assert {:ok, address} =
               IPAM.create_ip_address(context.admin, %{
                 address: "2001:DB8:0:0::10/64",
                 allocation_state: "allocated",
                 management_mode: "slaac"
               })

      assert Cidr.format(address.address) == "2001:db8::10/64"
      assert Repo.get!(Resource, address.resource_id).display_name == "2001:db8::10"

      assert {:error, changeset} =
               IPAM.create_ip_address(context.admin, %{address: "2001:db8::10/128"})

      assert %{address: ["is already managed in this routing table"]} = errors_on(changeset)

      assert {:ok, %{assignments: [%{interface_id: eth0_id}]}} =
               IPAM.assign_address(context.admin, address.id, context.eth0.id)

      assert eth0_id == context.eth0.id

      assert [%{id: id}] = IPAM.list_ip_addresses(context.admin, %{"q" => "2001:db8::10"})
      assert id == address.id
    end

    test "refuses invalid input, another organization's VRF, and members", context do
      foreign = vrf_fixture(scope_for(organization_fixture(), "admin"), "blue")

      assert {:error, changeset} = IPAM.create_ip_address(context.admin, %{address: "nope"})
      assert %{address: ["is invalid"]} = errors_on(changeset)

      assert {:error, changeset} =
               IPAM.create_ip_address(context.admin, %{address: "192.0.2.1", role: "router"})

      assert %{role: ["is invalid"]} = errors_on(changeset)

      assert {:error, changeset} =
               IPAM.create_ip_address(context.admin, %{address: "192.0.2.1", vrf_id: foreign.id})

      assert %{vrf_id: ["does not exist"]} = errors_on(changeset)

      member = scope_for(context.organization, "member")
      assert {:error, :forbidden} = IPAM.create_ip_address(member, %{address: "192.0.2.1"})
      assert Repo.aggregate(IpAddress, :count) == 0
    end
  end

  describe "assignments" do
    test "an ordinary address takes one interface; a shared role takes several", context do
      {:ok, address} = IPAM.create_ip_address(context.admin, %{address: "192.0.2.20/24"})

      assert {:ok, assigned} = IPAM.assign_address(context.admin, address.id, context.eth0.id)
      assert [%{interface_id: eth0_id}] = assigned.assignments
      assert eth0_id == context.eth0.id

      assert {:error, changeset} =
               IPAM.assign_address(context.admin, address.id, context.eth0.id)

      assert %{interface_id: ["already has this address"]} = errors_on(changeset)

      assert {:error, changeset} =
               IPAM.assign_address(context.admin, address.id, context.other_eth0.id)

      assert %{interface_id: [message]} = errors_on(changeset)
      assert message =~ "only a VIP, anycast, or first-hop redundancy role is shared"

      # As a VIP it can float between both load balancers.
      {:ok, vip} = IPAM.update_ip_address(context.admin, assigned, %{role: "vip"})
      assert {:ok, shared} = IPAM.assign_address(context.admin, vip.id, context.other_eth0.id)
      assert length(shared.assignments) == 2

      descriptions =
        context.admin
        |> Inventory.list_activity()
        |> Enum.filter(&(&1.resource_id == address.resource_id))
        |> Enum.map(&RengaWeb.ChangeDescription.describe/1)

      assert "Assigned to eth0 on #{context.host.name}" in descriptions
      assert "Assigned to eth0 on #{context.other_host.name}" in descriptions
      assert "Updated role" in descriptions
    end

    test "a shared address keeps its role until one assignment remains", context do
      {:ok, vip} =
        IPAM.create_ip_address(context.admin, %{address: "192.0.2.30/24", role: "anycast"})

      {:ok, _} = IPAM.assign_address(context.admin, vip.id, context.eth0.id)
      {:ok, shared} = IPAM.assign_address(context.admin, vip.id, context.other_eth0.id)

      assert {:error, changeset} =
               IPAM.update_ip_address(context.admin, shared, %{role: "ordinary"})

      assert %{role: ["is shared by 2 interfaces; remove all but one assignment first"]} =
               errors_on(changeset)

      # Removing one assignment leaves the other and the address in place.
      [first, _second] = shared.assignments
      assert {:ok, remaining} = IPAM.unassign_address(context.admin, first.id)
      assert [%{id: kept}] = remaining.assignments
      refute kept == first.id
      assert Repo.get!(Resource, vip.resource_id).lifecycle_state == "active"

      assert {:ok, %{role: "ordinary"}} =
               IPAM.update_ip_address(context.admin, remaining, %{role: "ordinary"})
    end

    test "assignments stay inside the organization and off released addresses", context do
      {:ok, address} = IPAM.create_ip_address(context.admin, %{address: "192.0.2.40"})
      other = scope_for(organization_fixture(), "admin")
      {_host, foreign_ports} = device_fixture(other, "server", "foreign", ~w(eth0))

      assert_raise Ecto.NoResultsError, fn ->
        IPAM.assign_address(context.admin, address.id, foreign_ports["eth0"].id)
      end

      assert_raise Ecto.NoResultsError, fn ->
        IPAM.assign_address(other, address.id, foreign_ports["eth0"].id)
      end

      # The database refuses the cross-organization pair too, whatever code
      # reaches it.
      assert {:error, changeset} =
               %IpAddressAssignment{
                 organization_id: context.admin.organization_id,
                 ip_address_id: address.id,
                 interface_id: foreign_ports["eth0"].id
               }
               |> IpAddressAssignment.changeset()
               |> Repo.insert()

      assert %{interface_id: ["does not exist"]} = errors_on(changeset)

      member = scope_for(context.organization, "member")
      assert {:error, :forbidden} = IPAM.assign_address(member, address.id, context.eth0.id)

      {:ok, _} = IPAM.release_address(context.admin, address.id)

      assert {:error, :retired} =
               IPAM.assign_address(context.admin, address.id, context.eth0.id)
    end
  end

  describe "editing" do
    test "records each changed field and refuses stale or released edits", context do
      {:ok, address} = IPAM.create_ip_address(context.admin, %{address: "192.0.2.50/24"})

      assert {:ok, updated} =
               IPAM.update_ip_address(context.admin, address, %{
                 allocation_state: "allocated",
                 management_mode: "dhcp",
                 dns_name: "db.example.net",
                 # Identity does not change through an edit.
                 address: "192.0.2.99/24"
               })

      assert Cidr.format(updated.address) == "192.0.2.50/24"

      changes =
        context.admin
        |> Inventory.list_activity()
        |> Enum.filter(&(&1.resource_id == address.resource_id and &1.kind == "updated"))
        |> Map.new(&{&1.field, {&1.old_value["value"], &1.new_value["value"]}})

      assert changes == %{
               "allocation_state" => {"reserved", "allocated"},
               "management_mode" => {nil, "dhcp"},
               "dns_name" => {nil, "db.example.net"}
             }

      assert {:error, :stale} =
               IPAM.update_ip_address(context.admin, address, %{description: "Old form"})

      member = scope_for(context.organization, "member")
      assert {:error, :forbidden} = IPAM.update_ip_address(member, updated, %{role: "vip"})

      {:ok, _} = IPAM.release_address(context.admin, address.id)
      assert {:error, :retired} = IPAM.update_ip_address(context.admin, updated, %{role: "vip"})
    end
  end

  describe "adopt, release, and re-adopt" do
    test "one canonical record across the cycle; observations keep occupying space", context do
      lan = prefix_fixture(context.admin, "192.0.2.0/28")
      observed = address_fixture(context.admin, context.eth0, "192.0.2.5/28")
      address_fixture(context.admin, context.other_eth0, "192.0.2.5/28")

      {:ok, adopted} = IPAM.adopt_address(context.admin, observed.id)
      {:ok, vip} = IPAM.update_ip_address(context.admin, adopted, %{role: "vip"})
      {:ok, shared} = IPAM.assign_address(context.admin, vip.id, context.other_eth0.id)
      assert length(shared.assignments) == 2

      # Release ends every assignment of the shared address and retires it.
      {:ok, _} = IPAM.release_address(context.admin, adopted.id)
      assert Repo.preload(Repo.get!(IpAddress, adopted.id), :assignments).assignments == []

      # The observed host still uses its space, now observed-only.
      view = IPAM.prefix_view(context.admin, lan)
      assert Enum.all?(view.addresses, &is_nil(&1.managed))
      assert view.address_map.used == 1

      # Re-adoption reactivates the same record as new, ordinary intent on
      # the one interface it was adopted from; the old shared role is gone.
      {:ok, readopted} = IPAM.adopt_address(context.admin, observed.id)
      assert readopted.id == adopted.id
      assert Repo.reload!(readopted).role == "ordinary"
      assert [%{interface_id: eth0_id}] = readopted.assignments
      assert eth0_id == context.eth0.id

      assert {:error, changeset} =
               IPAM.assign_address(context.admin, readopted.id, context.other_eth0.id)

      assert %{interface_id: [_]} = errors_on(changeset)

      assert [%{managed: %{id: managed_id}} | _] = IPAM.prefix_view(context.admin, lan).addresses
      assert managed_id == adopted.id
    end
  end

  defp scope_for(organization, role) do
    user = user_fixture()
    organization_membership_fixture(user, organization, %{role: role})
    Accounts.scope_for_user(user, organization.id)
  end
end
