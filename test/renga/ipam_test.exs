defmodule Renga.IPAMTest do
  use Renga.DataCase, async: true

  import Renga.AccountsFixtures
  import Renga.InventoryFixtures
  import Renga.TopologyFixtures

  alias Renga.Accounts
  alias Renga.IPAM
  alias Renga.Topology

  setup do
    user = user_fixture()
    organization = organization_fixture()
    organization_membership_fixture(user, organization, %{role: "admin"})
    %{scope: Accounts.scope_for_user(user, organization.id)}
  end

  test "lists each family's tree for one routing table with usage", %{scope: scope} do
    site = prefix_fixture(scope, "10.0.0.0/16")
    users_v4 = prefix_fixture(scope, "10.0.10.0/24")
    users_v6 = prefix_fixture(scope, "2001:db8:a:10::/64")
    prefix_fixture(scope, "10.0.0.0/16", %{vrf: "blue"})

    {_host, ports} = device_fixture(scope, "server", "ipam-host", ~w(eth0))
    address_fixture(scope, ports["eth0"], "10.0.10.5")
    address_fixture(scope, ports["eth0"], "10.0.10.6")
    address_fixture(scope, ports["eth0"], "2001:db8:a:10::15")

    assert IPAM.list_routing_tables(scope) == [nil, "blue"]

    %{ipv4: ipv4, ipv6: ipv6} = IPAM.list_prefix_rows(scope, nil)

    assert Enum.map(ipv4, &{&1.node.prefix.id, &1.depth}) == [{site.id, 0}, {users_v4.id, 1}]

    assert %{kind: :children, allocated: 1, total: 256, level: 24} = hd(ipv4).usage
    assert %{kind: :percent, used: 2, usable: 254, percent: 1} = List.last(ipv4).usage
    assert [%{usage: %{kind: :count, count: 1}}] = ipv6
    assert hd(ipv6).node.prefix.id == users_v6.id

    assert %{ipv4: [blue], ipv6: []} = IPAM.list_prefix_rows(scope, "blue")
    assert blue.node.prefix.vrf == "blue"
  end

  test "pairs prefixes through the VLAN they serve and marks single-stack ones", %{scope: scope} do
    group = vlan_group_fixture(scope, "ipam")
    users = vlan_fixture(scope, group, 10, "users")
    voice = vlan_fixture(scope, group, 20, "voice")
    users_v4 = prefix_fixture(scope, "10.0.10.0/24")
    users_v6 = prefix_fixture(scope, "2001:db8:a:10::/64")
    voice_v4 = prefix_fixture(scope, "10.0.20.0/24")
    {:ok, _} = Topology.attach_prefix_vlan(scope, users_v4.id, users.id)
    {:ok, _} = Topology.attach_prefix_vlan(scope, users_v6.id, users.id)
    {:ok, _} = Topology.attach_prefix_vlan(scope, voice_v4.id, voice.id)

    %{ipv4: ipv4, ipv6: [v6_row]} = IPAM.list_prefix_rows(scope, nil)
    users_row = Enum.find(ipv4, &(&1.node.prefix.id == users_v4.id))
    voice_row = Enum.find(ipv4, &(&1.node.prefix.id == voice_v4.id))

    assert Enum.map(users_row.counterparts, & &1.id) == [users_v6.id]
    assert Enum.map(v6_row.counterparts, & &1.id) == [users_v4.id]
    refute users_row.single_stack?
    assert voice_row.single_stack?
    assert Enum.map(voice_row.vlans, & &1.vid) == [20]
  end

  test "builds a prefix's view with ancestors, children, and addresses", %{scope: scope} do
    site = prefix_fixture(scope, "2001:db8:a::/48")
    hall = prefix_fixture(scope, "2001:db8:a::/56")
    lan = prefix_fixture(scope, "2001:db8:a:10::/64")
    prefix_fixture(scope, "2001:db8:a:100::/56")
    prefix_fixture(scope, "2001:db8:a::/48", %{vrf: "blue"})

    {_host, ports} = device_fixture(scope, "server", "view-host", ~w(eth0))
    address_fixture(scope, ports["eth0"], "2001:db8:a:10::15", %{"assignment" => "static"})

    address_fixture(scope, ports["eth0"], "2001:db8:a:10:a1b2:c3d4:e5f6:1", %{"temporary" => true})

    address_fixture(scope, ports["eth0"], "10.9.9.9")

    site_view = IPAM.prefix_view(scope, IPAM.get_prefix!(scope, site.id))
    assert site_view.mode == :container
    assert site_view.ancestors == []
    assert {site_view.space.allocated, site_view.space.total} == {2, 256}

    lan_view = IPAM.prefix_view(scope, IPAM.get_prefix!(scope, lan.id))
    assert lan_view.mode == :address_table
    assert Enum.map(lan_view.ancestors, & &1.id) == [site.id, hall.id]

    assert Enum.map(lan_view.addresses, &{&1.method, &1.temporary?}) ==
             [{:static, false}, {:slaac, true}]

    assert hd(lan_view.addresses).address.interface.resource.name == "view-host"
  end

  test "maps every address of a small IPv4 leaf", %{scope: scope} do
    lan = prefix_fixture(scope, "192.0.2.0/28")
    {_host, ports} = device_fixture(scope, "server", "map-host", ~w(eth0))
    address_fixture(scope, ports["eth0"], "192.0.2.3")

    view = IPAM.prefix_view(scope, IPAM.get_prefix!(scope, lan.id))

    assert view.mode == :address_map
    assert length(view.address_map.cells) == 16
    assert Enum.at(view.address_map.cells, 3).state == :used
    assert {view.address_map.used, view.address_map.usable} == {1, 14}
  end

  test "list utilization matches distinct usable hosts in detail, regardless of inventory masks",
       %{scope: scope} do
    {_host, ports} = device_fixture(scope, "server", "duplicates", ~w(eth0 eth1))
    for port <- Map.values(ports), do: address_fixture(scope, port, "192.0.2.1/24")
    address_fixture(scope, ports["eth0"], "192.0.2.0/24")
    address_fixture(scope, ports["eth0"], "192.0.2.3/24")

    for {cidr, used, usable, percent} <- [
          {"192.0.2.0/30", 1, 2, 50},
          {"192.0.2.0/31", 2, 2, 100},
          {"192.0.2.1/32", 1, 1, 100}
        ] do
      prefix = prefix_fixture(scope, cidr, %{vrf: cidr})
      %{ipv4: [row]} = IPAM.list_prefix_rows(scope, cidr)
      view = IPAM.prefix_view(scope, prefix)
      assert %{used: ^used, usable: ^usable, percent: ^percent} = row.usage
      assert %{used: ^used, usable: ^usable, percent: ^percent} = view.address_map
    end
  end

  test "address tables count a host once however many interfaces report it", %{scope: scope} do
    {_host, ports} = device_fixture(scope, "server", "table-duplicates", ~w(eth0 eth1))

    for {cidr, address} <- [{"2001:db8::/64", "2001:db8::1/48"}, {"192.0.0.0/21", "192.0.2.1/16"}] do
      prefix = prefix_fixture(scope, cidr, %{vrf: cidr})
      for port <- Map.values(ports), do: address_fixture(scope, port, address)
      address_fixture(scope, ports["eth0"], String.replace(address, ~r/1\//, "2/"))
      rows = IPAM.list_prefix_rows(scope, cidr)
      [row] = rows.ipv4 ++ rows.ipv6
      assert row.usage == %{kind: :count, count: 2}
      # Detail still lists each interface's record.
      assert length(IPAM.prefix_view(scope, prefix).addresses) == 3
    end
  end

  test "uses current ingestion evidence and excludes withdrawn addresses without deleting history",
       %{scope: scope} do
    v4 = prefix_fixture(scope, "192.0.2.0/28")
    v6 = prefix_fixture(scope, "2001:db8:1::/80")
    {:ok, source} = Renga.Inventory.create_source(scope, %{kind: "host_agent", name: "ipam"})

    payload = [
      "192.0.2.5/24",
      %{"address" => "2001:db8:1::15/64", "metadata" => %{"assignment" => "dhcpv6"}},
      %{"address" => "2001:db8:1::99/64", "metadata" => %{"temporary" => true}}
    ]

    report_addresses(scope, source, payload)
    assert %{address_map: %{used: 1}} = IPAM.prefix_view(scope, v4)

    assert %{
             addresses: [%{method: :dhcp, temporary?: false}, %{method: :slaac, temporary?: true}]
           } = IPAM.prefix_view(scope, v6)

    report_addresses(scope, source, [
      %{"address" => "2001:db8:1::15/64", "metadata" => %{"assignment" => "static"}}
    ])

    assert %{addresses: [%{method: :static}]} = IPAM.prefix_view(scope, v6)
    assert %{address_map: %{used: 0}} = IPAM.prefix_view(scope, v4)
    retained = report_addresses(scope, source, [])
    assert length(retained) == 3
    assert Enum.all?(retained, &(&1.metadata["present"] == false))
    assert %{addresses: []} = IPAM.prefix_view(scope, v6)

    assert %{ipv4: [%{usage: %{used: 0}}], ipv6: [%{usage: %{count: 0}}]} =
             IPAM.list_prefix_rows(scope, nil)
  end

  test "adopts and releases addresses, owners and admins only", %{scope: scope} do
    {_host, ports} = device_fixture(scope, "server", "adopt-host", ~w(eth0))
    address = address_fixture(scope, ports["eth0"], "192.0.2.5")

    assert {:ok, managed} = IPAM.adopt_address(scope, address.id)
    assert managed.interface_id == ports["eth0"].id
    assert managed.adopted_by_id == scope.user.id
    assert {:error, %Ecto.Changeset{}} = IPAM.adopt_address(scope, address.id)

    member = user_fixture()

    organization_membership_fixture(
      member,
      Renga.Repo.get!(Renga.Accounts.Organization, scope.organization_id),
      %{role: "member"}
    )

    member_scope = Accounts.scope_for_user(member, scope.organization_id)
    assert {:error, :forbidden} = IPAM.release_address(member_scope, managed.id)
    assert {:error, :forbidden} = IPAM.adopt_address(member_scope, address.id)

    assert {:ok, _released} = IPAM.release_address(scope, managed.id)
  end

  test "managed identity ignores interface masks and persists after interface or resource deletion",
       %{scope: scope} do
    for {text, host, mask} <- [
          {"192.0.2.5/24", "192.0.2.5/32", 32},
          {"2001:db8::5/64", "2001:db8::5/128", 128}
        ] do
      {resource, ports} = device_fixture(scope, "server", "identity-#{mask}", ~w(eth0 eth1))
      first = address_fixture(scope, ports["eth0"], text)
      second = address_fixture(scope, ports["eth1"], host)
      assert {:ok, managed} = IPAM.adopt_address(scope, first.id)
      assert managed.address.netmask == mask
      assert Renga.Repo.reload!(first).address.netmask != mask
      assert {:error, %Ecto.Changeset{}} = IPAM.adopt_address(scope, second.id)
      invalid = %{managed | id: nil, address: first.address}

      changeset =
        invalid
        |> Ecto.Changeset.change()
        |> Ecto.Changeset.check_constraint(:address, name: :managed_addresses_host_address)

      assert {:error, %Ecto.Changeset{}} = Renga.Repo.insert(changeset, mode: :savepoint)
      if mask == 32, do: Renga.Repo.delete!(ports["eth0"]), else: Renga.Repo.delete!(resource)
      assert %{interface_id: nil, organization_id: organization_id} = Renga.Repo.reload!(managed)
      assert organization_id == scope.organization_id
      assert {:ok, _} = IPAM.release_address(scope, managed.id)
    end
  end

  test "cannot adopt or release another tenant's address", %{scope: scope} do
    other = user_fixture()
    organization = organization_fixture()
    organization_membership_fixture(other, organization, %{role: "admin"})
    other_scope = Accounts.scope_for_user(other, organization.id)
    {_host, ports} = device_fixture(other_scope, "server", "foreign-adoption", ~w(eth0))
    address = address_fixture(other_scope, ports["eth0"], "192.0.2.5/24")
    assert_raise Ecto.NoResultsError, fn -> IPAM.adopt_address(scope, address.id) end
    assert {:ok, managed} = IPAM.adopt_address(other_scope, address.id)
    assert_raise Ecto.NoResultsError, fn -> IPAM.release_address(scope, managed.id) end
    assert Renga.Repo.reload!(managed)
  end

  test "coverage tracks authoritative withdrawal and reappearance using host containment", %{
    scope: scope
  } do
    group = vlan_group_fixture(scope, "withdrawal")
    vlan = vlan_fixture(scope, group, 10, "users")

    for cidr <- ["192.0.2.0/28", "2001:db8:1::/80"] do
      prefix = prefix_fixture(scope, cidr)
      {:ok, _} = Topology.attach_prefix_vlan(scope, prefix.id, vlan.id)
    end

    {:ok, source} = Renga.Inventory.create_source(scope, %{kind: "host_agent", name: "coverage"})
    addresses = report_addresses(scope, source, ["192.0.2.5/24", "2001:db8:1::5/64"])
    v6 = Enum.find(addresses, &(&1.kind == "ipv6"))
    assert %{total: 1, both: [_]} = IPAM.vlan_dual_stack(scope, vlan.id)
    report_addresses(scope, source, ["192.0.2.5/24"])
    assert %{both: [], missing_ipv6: [_], total: 1} = IPAM.vlan_dual_stack(scope, vlan.id)
    assert_raise Ecto.NoResultsError, fn -> IPAM.adopt_address(scope, v6.id) end
    report_addresses(scope, source, [])
    assert %{total: 0} = IPAM.vlan_dual_stack(scope, vlan.id)
    report_addresses(scope, source, ["192.0.2.5/24", "2001:db8:1::5/64"])
    assert %{total: 1, both: [_]} = IPAM.vlan_dual_stack(scope, vlan.id)
  end

  test "measures dual-stack coverage only for VLANs carrying both families", %{scope: scope} do
    group = vlan_group_fixture(scope, "dual")
    users = vlan_fixture(scope, group, 10, "users")
    voice = vlan_fixture(scope, group, 20, "voice")
    v4 = prefix_fixture(scope, "10.0.10.0/24")
    v6 = prefix_fixture(scope, "2001:db8:a:10::/64")
    voice_v4 = prefix_fixture(scope, "10.0.20.0/24")
    {:ok, _} = Topology.attach_prefix_vlan(scope, v4.id, users.id)
    {:ok, _} = Topology.attach_prefix_vlan(scope, v6.id, users.id)
    {:ok, _} = Topology.attach_prefix_vlan(scope, voice_v4.id, voice.id)

    {both, both_ports} = device_fixture(scope, "server", "both", ~w(eth0))
    {v4_only, v4_ports} = device_fixture(scope, "server", "v4-only", ~w(eth0))
    {v6_only, v6_ports} = device_fixture(scope, "server", "v6-only", ~w(eth0))
    address_fixture(scope, both_ports["eth0"], "10.0.10.5")
    address_fixture(scope, both_ports["eth0"], "2001:db8:a:10::5")
    address_fixture(scope, v4_ports["eth0"], "10.0.10.6")
    address_fixture(scope, v6_ports["eth0"], "2001:db8:a:10::7")

    coverage = IPAM.vlan_dual_stack(scope, users.id)

    assert Enum.map(coverage.both, & &1.id) == [both.id]
    assert Enum.map(coverage.missing_ipv6, & &1.id) == [v4_only.id]
    assert Enum.map(coverage.missing_ipv4, & &1.id) == [v6_only.id]
    assert coverage.total == 3
    assert IPAM.vlan_dual_stack(scope, voice.id) == nil
  end

  test "never shows another organization's prefixes or addresses", %{scope: scope} do
    lan = prefix_fixture(scope, "192.0.2.0/28")

    other = user_fixture()
    other_organization = organization_fixture()
    organization_membership_fixture(other, other_organization, %{role: "admin"})
    other_scope = Accounts.scope_for_user(other, other_organization.id)
    {_host, ports} = device_fixture(other_scope, "server", "other-host", ~w(eth0))
    address_fixture(other_scope, ports["eth0"], "192.0.2.3")

    assert IPAM.list_prefix_rows(other_scope, nil) == %{ipv4: [], ipv6: []}
    assert_raise Ecto.NoResultsError, fn -> IPAM.get_prefix!(other_scope, lan.id) end

    view = IPAM.prefix_view(scope, IPAM.get_prefix!(scope, lan.id))
    assert view.address_map.used == 0
  end
end
