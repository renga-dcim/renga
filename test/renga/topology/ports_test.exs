defmodule Renga.Topology.PortsTest do
  use Renga.DataCase, async: true

  import Renga.AccountsFixtures
  import Renga.InventoryFixtures
  import Renga.TopologyFixtures

  alias Renga.Accounts
  alias Renga.Inventory
  alias Renga.Topology
  alias Renga.Topology.Ports

  setup do
    user = user_fixture()
    organization = organization_fixture()
    organization_membership_fixture(user, organization, %{role: "admin"})
    %{scope: Accounts.scope_for_user(user, organization.id)}
  end

  test "orders ports as people count them" do
    names = ~w(swp10 swp2 Ethernet1/10 swp1 Ethernet1/2)

    assert Enum.sort_by(names, &Ports.natural_key/1) ==
             ~w(Ethernet1/2 Ethernet1/10 swp1 swp2 swp10)
  end

  test "lists a switch's physical ports with neighbor, cable, and VLANs", %{scope: scope} do
    group = vlan_group_fixture(scope, "ports")
    users = vlan_fixture(scope, group, 10, "users")
    voice = vlan_fixture(scope, group, 20, "voice")
    storage = vlan_fixture(scope, group, 30, "storage")

    {leaf, leaf_ports} = device_fixture(scope, "switch", "ports-leaf", ~w(swp10 swp2 swp1))
    {host, host_ports} = device_fixture(scope, "server", "ports-host", ~w(eth0))
    {:ok, _bond} = Inventory.create_interface(scope, leaf.id, %{name: "bond0", kind: "bond"})

    cable_fixture(scope, leaf_ports["swp1"], host_ports["eth0"])
    report_neighbors(scope, leaf, %{"swp1" => {host.name, "eth0"}, "swp2" => {"ghost", "p1"}})

    desire_vlans(scope, leaf_ports["swp1"], "trunk", users, [voice])
    desire_vlans(scope, leaf_ports["swp2"], "access", users)

    report_vlans(scope, leaf, group, %{
      "swp1" => {"trunk", [{10, "untagged"}, {30, "tagged"}]},
      "swp2" => {"access", [{10, "untagged"}]}
    })

    assert [swp1, swp2, swp10] = Topology.list_resource_ports(scope, leaf.id)
    assert Enum.map([swp1, swp2, swp10], & &1.interface.name) == ~w(swp1 swp2 swp10)

    assert swp1.cable.state == :agreeing
    assert swp1.neighbor == swp1.cable
    assert Ports.far_end(swp1, swp1.cable).name == "eth0"

    assert swp1.desired.mode == "trunk"
    assert swp1.desired.untagged.id == users.id
    assert Enum.map(swp1.observed.tagged, & &1.vid) == [30]
    assert Enum.map(swp1.desired.tagged, & &1.id) == [voice.id]

    # Marks follow reconciliation's findings: this partial snapshot flags
    # the unexpected VLAN but does not claim the desired one is missing.
    assert [%{tagging: :tagged, vlan: %{id: storage_id}}] = swp1.unexpected
    assert storage_id == storage.id
    assert swp1.missing == []
    assert Ports.drift?(swp1)
    assert Enum.map(swp1.findings, & &1.kind) == ["unexpected_vlan"]

    refute Ports.drift?(swp2)
    assert swp2.missing == [] and swp2.unexpected == []
    assert [%{remote_chassis_id: "ghost"}] = swp2.unresolved
    assert swp2.neighbor == nil

    assert swp10.desired == nil and swp10.observed == nil
  end

  test "never lists another organization's ports", %{scope: scope} do
    {leaf, _ports} = device_fixture(scope, "switch", "own-ports", ~w(swp1))

    other = user_fixture()
    other_organization = organization_fixture()
    organization_membership_fixture(other, other_organization, %{role: "admin"})
    other_scope = Accounts.scope_for_user(other, other_organization.id)

    assert Topology.list_resource_ports(other_scope, leaf.id) == []
  end
end
