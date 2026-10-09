defmodule Renga.Topology.VlanUsageTest do
  use Renga.DataCase, async: true

  import Renga.AccountsFixtures
  import Renga.InventoryFixtures
  import Renga.TopologyFixtures

  alias Renga.Accounts
  alias Renga.Topology
  alias Renga.Topology.VlanUsage

  setup do
    user = user_fixture()
    organization = organization_fixture()
    organization_membership_fixture(user, organization, %{role: "admin"})
    %{scope: Accounts.scope_for_user(user, organization.id)}
  end

  test "summarises a group's ranges and the VIDs used in them" do
    group = %{vid_ranges: [%{start_vid: 200, end_vid: 299}, %{start_vid: 1, end_vid: 100}]}

    assert %{capacity: 200, used: 3, segments: [low, high]} =
             VlanUsage.strip(group, [250, 10, 20, 150])

    assert {low.start_vid, low.end_vid, low.size, low.used} == {1, 100, 100, [10, 20]}
    assert high.used == [250]
  end

  test "compares planned and observed membership per interface", %{scope: scope} do
    group = vlan_group_fixture(scope, "members")
    users = vlan_fixture(scope, group, 10, "users")
    vlan_fixture(scope, group, 20, "voice")

    {leaf, ports} = device_fixture(scope, "switch", "members-leaf", ~w(swp1 swp2 swp3 swp4))
    desire_vlans(scope, ports["swp1"], "trunk", users)
    desire_vlans(scope, ports["swp2"], "trunk", nil, [users])
    desire_vlans(scope, ports["swp3"], "access", users)

    report_vlans(scope, leaf, group, %{
      "swp1" => {"trunk", [{10, "untagged"}]},
      "swp2" => {"trunk", [{10, "untagged"}]},
      "swp4" => {"trunk", [{10, "tagged"}]}
    })

    members = Topology.list_vlan_members(scope, users.id)

    assert Enum.map(members, &{&1.interface.name, &1.planned, &1.observed, &1.state}) == [
             {"swp2", "tagged", "untagged", :tagging_differs},
             {"swp3", "untagged", nil, :planned_only},
             {"swp4", nil, "tagged", :observed_only},
             {"swp1", "untagged", "untagged", :both}
           ]

    assert VlanUsage.member_counts(members) ==
             %{both: 1, tagging_differs: 1, planned_only: 1, observed_only: 1}

    assert Topology.vlan_member_counts(scope) == %{users.id => %{planned: 3, observed: 3}}
  end

  test "never counts another organization's members", %{scope: scope} do
    group = vlan_group_fixture(scope, "own-members")
    users = vlan_fixture(scope, group, 10, "users")
    {_leaf, ports} = device_fixture(scope, "switch", "own-members-leaf", ~w(swp1))
    desire_vlans(scope, ports["swp1"], "access", users)

    other = user_fixture()
    other_organization = organization_fixture()
    organization_membership_fixture(other, other_organization, %{role: "admin"})
    other_scope = Accounts.scope_for_user(other, other_organization.id)

    assert Topology.vlan_member_counts(other_scope) == %{}
    assert Topology.list_vlan_members(other_scope, users.id) == []
  end
end
