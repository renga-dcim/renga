defmodule Renga.IPAMTest do
  use Renga.DataCase, async: true

  import Renga.AccountsFixtures
  import Renga.InventoryFixtures
  import Renga.TopologyFixtures

  alias Renga.Accounts
  alias Renga.IPAM
  alias Renga.IPAM.Cidr
  alias Renga.IPAM.IpAddress
  alias Renga.IPAM.IpAddressAssignment
  alias Renga.IPAM.Vrf
  alias Renga.Repo
  alias Renga.Topology

  setup do
    user = user_fixture()
    organization = organization_fixture()
    organization_membership_fixture(user, organization, %{role: "admin"})
    %{scope: Accounts.scope_for_user(user, organization.id)}
  end

  test "strict policy rejects nil without writes and preserves omitted values", %{scope: scope} do
    events = Repo.aggregate(Renga.Inventory.ChangeEvent, :count)
    assert {:error, changeset} = IPAM.create_prefix(scope, %{prefix: "192.0.2.0/24", strict: nil})
    assert errors_on(changeset).strict == ["can't be blank"]
    assert Repo.aggregate(Renga.Inventory.Prefix, :count) == 0
    assert Repo.aggregate(Renga.Inventory.ChangeEvent, :count) == events

    assert {:ok, prefix} = IPAM.create_prefix(scope, %{prefix: "192.0.2.0/24"})
    refute prefix.strict
    assert {:ok, prefix} = IPAM.update_prefix(scope, prefix, %{strict: true})
    events = Repo.aggregate(Renga.Inventory.ChangeEvent, :count)
    assert {:error, changeset} = IPAM.update_prefix(scope, prefix, %{strict: nil})
    assert errors_on(changeset).strict == ["can't be blank"]
    assert Repo.reload!(prefix).strict
    assert Repo.aggregate(Renga.Inventory.ChangeEvent, :count) == events
    assert {:ok, prefix} = IPAM.update_prefix(scope, prefix, %{description: "unchanged policy"})
    assert prefix.strict
    assert {:ok, prefix} = IPAM.update_prefix(scope, prefix, %{strict: false})
    refute prefix.strict
  end

  test "lists each family's tree for one routing table with usage", %{scope: scope} do
    site = prefix_fixture(scope, "10.0.0.0/16", %{status: "container"})
    users_v4 = prefix_fixture(scope, "10.0.10.0/24")
    users_v6 = prefix_fixture(scope, "2001:db8:a:10::/64")
    prefix_fixture(scope, "10.0.0.0/16", %{vrf: "blue"})

    {_host, ports} = device_fixture(scope, "server", "ipam-host", ~w(eth0))
    address_fixture(scope, ports["eth0"], "10.0.10.5")
    address_fixture(scope, ports["eth0"], "10.0.10.6")
    address_fixture(scope, ports["eth0"], "2001:db8:a:10::15")

    assert [nil, %Vrf{name: "blue"} = blue_vrf] = IPAM.list_routing_tables(scope)

    %{ipv4: ipv4, ipv6: ipv6} = IPAM.list_prefix_rows(scope, nil)

    assert Enum.map(ipv4, &{&1.node.prefix.id, &1.depth}) == [{site.id, 0}, {users_v4.id, 1}]

    assert %{kind: :children, allocated: 1, total: 256, level: 24} = hd(ipv4).usage
    assert %{kind: :percent, used: 2, usable: 254, percent: 1} = List.last(ipv4).usage
    assert [%{usage: %{kind: :count, count: 1}}] = ipv6
    assert hd(ipv6).node.prefix.id == users_v6.id

    assert %{ipv4: [blue], ipv6: []} = IPAM.list_prefix_rows(scope, blue_vrf.id)
    assert blue.node.prefix.vrf_id == blue_vrf.id
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
      # One prefix at a time, so the overlapping CIDRs never nest.
      prefix = prefix_fixture(scope, cidr)
      %{ipv4: [row]} = IPAM.list_prefix_rows(scope, nil)
      view = IPAM.prefix_view(scope, prefix)
      assert %{used: ^used, usable: ^usable, percent: ^percent} = row.usage
      assert %{used: ^used, usable: ^usable, percent: ^percent} = view.address_map
      {:ok, _} = IPAM.delete_prefix(scope, prefix)
    end
  end

  test "address tables count a host once however many interfaces report it", %{scope: scope} do
    {_host, ports} = device_fixture(scope, "server", "table-duplicates", ~w(eth0 eth1))

    for {cidr, address} <- [{"2001:db8::/64", "2001:db8::1/48"}, {"192.0.0.0/21", "192.0.2.1/16"}] do
      prefix = prefix_fixture(scope, cidr)
      for port <- Map.values(ports), do: address_fixture(scope, port, address)
      address_fixture(scope, ports["eth0"], String.replace(address, ~r/1\//, "2/"))
      rows = IPAM.list_prefix_rows(scope, nil)
      [row] = rows.ipv4 ++ rows.ipv6
      assert row.usage == %{kind: :count, count: 2}
      # Detail still lists each interface's record.
      assert length(IPAM.prefix_view(scope, prefix).addresses) == 3
      {:ok, _} = IPAM.delete_prefix(scope, prefix)
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
    {host, ports} = device_fixture(scope, "server", "adopt-host", ~w(eth0))
    address = address_fixture(scope, ports["eth0"], "192.0.2.5/24", %{"protocol" => "static"})

    assert {:ok, %IpAddress{} = managed} = IPAM.adopt_address(scope, address.id)
    assert managed.adopted_by_id == scope.user.id
    assert %{allocation_state: "allocated", role: "ordinary", vrf_id: nil} = managed
    assert managed.management_mode == "static"
    # The intended mask is the observed one.
    assert Cidr.format(managed.address) == "192.0.2.5/24"
    assert [%{interface_id: interface_id}] = managed.assignments
    assert interface_id == ports["eth0"].id

    resource = Repo.get!(Renga.Inventory.Resource, managed.resource_id)
    assert %{kind: "ip_address", display_name: "192.0.2.5", lifecycle_state: "active"} = resource
    assert "ip-address-" <> _uuid = resource.name

    assert {:error, %Ecto.Changeset{} = changeset} = IPAM.adopt_address(scope, address.id)
    assert %{address: ["is already managed in this routing table"]} = errors_on(changeset)

    member = user_fixture()

    organization_membership_fixture(
      member,
      Repo.get!(Renga.Accounts.Organization, scope.organization_id),
      %{role: "member"}
    )

    member_scope = Accounts.scope_for_user(member, scope.organization_id)
    assert {:error, :forbidden} = IPAM.release_address(member_scope, managed.id)
    assert {:error, :forbidden} = IPAM.adopt_address(member_scope, address.id)

    # Release retires the same record and ends its assignments.
    assert {:ok, released} = IPAM.release_address(scope, managed.id)
    assert released.resource.lifecycle_state == "retired"
    assert Repo.all(IpAddressAssignment) == []
    assert Repo.get!(IpAddress, managed.id)
    assert {:ok, _} = IPAM.release_address(scope, managed.id)

    # Re-adoption reactivates it rather than inserting a second record.
    assert {:ok, readopted} = IPAM.adopt_address(scope, address.id)
    assert readopted.id == managed.id
    assert Repo.get!(Renga.Inventory.Resource, managed.resource_id).lifecycle_state == "active"
    assert [_assignment] = readopted.assignments

    descriptions =
      scope
      |> Renga.Inventory.list_activity()
      |> Enum.filter(&(&1.resource_id == managed.resource_id))
      |> Enum.map(&RengaWeb.ChangeDescription.describe/1)
      |> Enum.frequencies()

    # Events written in one transaction share a timestamp, so compare counts.
    assert descriptions == %{
             "Created IP address 192.0.2.5" => 1,
             "Assigned to eth0 on #{host.name}" => 2,
             "Unassigned from eth0 on #{host.name}" => 1,
             "Updated lifecycle state" => 2
           }
  end

  test "managed identity is the host in its routing table; assignments go with interfaces",
       %{scope: scope} do
    for {text, host, mask} <- [
          {"192.0.2.5/24", "192.0.2.5/32", 24},
          {"2001:db8::5/64", "2001:db8::5/128", 64}
        ] do
      {resource, ports} = device_fixture(scope, "server", "identity-#{mask}", ~w(eth0 eth1))
      first = address_fixture(scope, ports["eth0"], text)
      second = address_fixture(scope, ports["eth1"], host)
      assert {:ok, managed} = IPAM.adopt_address(scope, first.id)
      assert managed.address.netmask == mask

      # The same host on another interface, with another mask, is the same
      # managed address.
      assert {:error, %Ecto.Changeset{}} = IPAM.adopt_address(scope, second.id)

      {:ok, envelope} =
        Renga.Inventory.ResourceStore.insert(scope.organization_id, %{
          kind: "ip_address",
          name: "duplicate-#{mask}",
          lifecycle_state: "active"
        })

      duplicate =
        %IpAddress{
          organization_id: scope.organization_id,
          resource_id: envelope.id,
          address: second.address
        }
        |> IpAddress.changeset(%{})

      assert {:error, changeset} = Repo.insert(duplicate, mode: :savepoint)
      assert %{address: ["is already managed in this routing table"]} = errors_on(changeset)

      if mask == 24, do: Repo.delete!(ports["eth0"]), else: Repo.delete!(resource)
      assert Repo.reload!(managed).organization_id == scope.organization_id
      assert Repo.all(from a in IpAddressAssignment, where: a.ip_address_id == ^managed.id) == []
      assert {:ok, _} = IPAM.release_address(scope, managed.id)
    end
  end

  test "a released address is history, and re-adoption records what changed", %{scope: scope} do
    lan = prefix_fixture(scope, "192.0.2.0/28")
    {:ok, source} = Renga.Inventory.create_source(scope, %{kind: "host_agent", name: "history"})

    [observed] =
      report_addresses(scope, source, [
        %{"address" => "192.0.2.5/24", "metadata" => %{"assignment" => "dhcp"}}
      ])

    # A newer historical hint must not outrank the canonical presence owner.
    evidence = Repo.get_by!(Renga.Inventory.AddressEvidence, address_id: observed.id)

    {:ok, history} =
      Renga.Inventory.create_observation(scope, source.id, %{
        idempotency_key: "non-winning-hint",
        observed_at: DateTime.add(evidence.observed_at, 1, :second),
        payload: %{}
      })

    %{evidence | id: nil, observation_id: history.id}
    |> Renga.Inventory.AddressEvidence.changeset(%{
      metadata: %{"assignment" => "slaac"},
      observed_at: history.observed_at
    })
    |> Repo.insert!()

    {:ok, managed} = IPAM.adopt_address(scope, observed.id)
    assert Repo.reload!(managed).management_mode == "dhcp"

    # Withdrawn, the managed address is still listed as current intent...
    report_addresses(scope, source, [])
    assert [%{address: nil, managed: %{id: id}}] = IPAM.prefix_view(scope, lan).addresses
    assert id == managed.id

    # ...until it is released, when only history remains.
    {:ok, _} = IPAM.release_address(scope, managed.id)
    assert IPAM.prefix_view(scope, lan).addresses == []

    # Seen again with another mask, the one observed assignment of the host
    # follows it, and so does the managed record when adopted again.
    [again] =
      report_addresses(scope, source, [
        %{"address" => "192.0.2.5/28", "metadata" => %{"assignment" => "static"}}
      ])

    assert again.id == observed.id

    adopter = user_fixture()
    organization = Repo.get!(Renga.Accounts.Organization, scope.organization_id)
    organization_membership_fixture(adopter, organization, %{role: "admin"})
    adopter_scope = Accounts.scope_for_user(adopter, organization.id)
    assert {:ok, readopted} = IPAM.adopt_address(adopter_scope, again.id, %{description: "Web"})
    assert readopted.id == managed.id
    persisted = Repo.reload!(readopted)
    assert Cidr.format(persisted.address) == "192.0.2.5/28"
    assert persisted.management_mode == "static"
    assert persisted.adopted_by_id == adopter.id

    changes =
      scope
      |> Renga.Inventory.list_activity()
      |> Enum.filter(&(&1.resource_id == managed.resource_id and &1.kind == "updated"))
      |> Map.new(&{&1.field, {&1.old_value["value"], &1.new_value["value"]}})

    assert changes["address"] == {"192.0.2.5/24", "192.0.2.5/28"}
    assert changes["management_mode"] == {"dhcp", "static"}
    assert changes["description"] == {nil, "Web"}
  end

  test "generic lifecycle writes cannot bypass IPAM release", %{scope: scope} do
    {host, ports} = device_fixture(scope, "server", "lifecycle-host", ~w(eth0))
    observed = address_fixture(scope, ports["eth0"], "192.0.2.5/24")
    {:ok, managed} = IPAM.adopt_address(scope, observed.id)

    assert {:error, changeset} =
             Renga.Inventory.update_resource(scope, managed.resource, %{
               lifecycle_state: "inactive"
             })

    assert %{lifecycle_state: ["is managed by IPAM"]} = errors_on(changeset)

    assert {:error, changeset} =
             Renga.Inventory.update_resource_lifecycle(scope, managed.resource, "retired")

    assert %{lifecycle_state: ["is managed by IPAM"]} = errors_on(changeset)

    assert {:error, _} =
             Renga.Inventory.update_resources_lifecycle(
               scope,
               [host.id, managed.resource_id],
               "retired"
             )

    assert Repo.reload!(host).lifecycle_state == "active"
    assert Repo.reload!(managed.resource).lifecycle_state == "active"
    assert [_] = Repo.all(IpAddressAssignment)

    assert {:ok, released} = IPAM.release_address(scope, managed.id)
    assert released.resource.lifecycle_state == "retired"
    assert released.assignments == []
  end

  test "IP-address envelopes are created only through the IPAM context", %{scope: scope} do
    assert {:error, changeset} =
             Renga.Inventory.create_resource(scope, %{kind: "ip_address", name: "loose"})

    assert %{kind: ["must be created through the IPAM context"]} = errors_on(changeset)
  end

  test "cannot adopt or release another tenant's address", %{scope: scope} do
    other = user_fixture()
    organization = organization_fixture()
    organization_membership_fixture(other, organization, %{role: "admin"})
    other_scope = Accounts.scope_for_user(other, organization.id)
    {_host, ports} = device_fixture(other_scope, "server", "foreign-adoption", ~w(eth0))
    address = address_fixture(other_scope, ports["eth0"], "192.0.2.5/24")
    assert {:error, :invalid_address} = IPAM.adopt_address(scope, address.id)
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
    assert {:error, :invalid_address} = IPAM.adopt_address(scope, v6.id)
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

  test "utilization is namespace-local, with observed addresses in the global table", %{
    scope: scope
  } do
    global_site = prefix_fixture(scope, "10.0.0.0/16", %{status: "container"})
    global_users = prefix_fixture(scope, "10.0.10.0/24")
    prefix_fixture(scope, "10.0.40.0/24")
    blue_site = prefix_fixture(scope, "10.0.0.0/16", %{vrf: "blue", status: "container"})
    blue_users = prefix_fixture(scope, "10.0.10.0/24", %{vrf: "blue"})
    prefix_fixture(scope, "10.0.20.0/23", %{vrf: "blue"})
    prefix_fixture(scope, "10.0.30.0/25", %{vrf: "blue"})

    {_host, ports} = device_fixture(scope, "server", "namespaces", ~w(eth0))
    address_fixture(scope, ports["eth0"], "10.0.10.5")
    managed = address_fixture(scope, ports["eth0"], "10.0.10.6")
    {:ok, _} = IPAM.adopt_address(scope, managed.id)

    usage = fn rows, prefix -> Enum.find(rows.ipv4, &(&1.node.prefix.id == prefix.id)).usage end

    global = IPAM.list_prefix_rows(scope, nil)
    blue = IPAM.list_prefix_rows(scope, blue_site.vrf_id)

    # The global table counts its own observed hosts and children only.
    assert %{used: 2} = usage.(global, global_users)
    assert %{kind: :children, allocated: 2, total: 256} = usage.(global, global_site)

    # A VRF counts the union of its own child space at its planning level
    # (/25 here: the /24 is 2 blocks, the /23 4, the /25 1), never the
    # global table's children or addresses.
    assert %{used: 0} = usage.(blue, blue_users)
    assert %{kind: :children, allocated: 7, total: 512, level: 25} = usage.(blue, blue_site)

    # Without a routing-domain claim the observed hosts are global.
    global_view = IPAM.prefix_view(scope, global_users)
    assert length(global_view.addresses) == 2
    assert global_view.address_map.used == 2

    blue_view = IPAM.prefix_view(scope, IPAM.get_prefix!(scope, blue_users.id))
    assert blue_view.addresses == []
    assert blue_view.address_map.used == 0
    refute Enum.any?(blue_view.address_map.cells, &(&1.state == :managed))
  end

  test "dual-stack coverage counts only the global table's prefixes", %{scope: scope} do
    group = vlan_group_fixture(scope, "dual-vrf")
    users = vlan_fixture(scope, group, 10, "users")
    v4 = prefix_fixture(scope, "10.0.10.0/24")
    v6 = prefix_fixture(scope, "2001:db8:a:10::/64", %{vrf: "blue"})
    {:ok, _} = Topology.attach_prefix_vlan(scope, v4.id, users.id)
    {:ok, _} = Topology.attach_prefix_vlan(scope, v6.id, users.id)

    {_both, ports} = device_fixture(scope, "server", "both-vrf", ~w(eth0))
    address_fixture(scope, ports["eth0"], "10.0.10.5")
    address_fixture(scope, ports["eth0"], "2001:db8:a:10::5")

    # The IPv6 side is in a VRF, where no address is observed yet, so there
    # is no coverage to report rather than a false "missing IPv6".
    assert IPAM.vlan_dual_stack(scope, users.id) == nil

    global_v6 = prefix_fixture(scope, "2001:db8:a:10::/64")
    {:ok, _} = Topology.attach_prefix_vlan(scope, global_v6.id, users.id)
    assert %{total: 1, both: [_]} = IPAM.vlan_dual_stack(scope, users.id)
  end

  test "usage follows status: containers by child space, others by occupied hosts", %{
    scope: scope
  } do
    empty = prefix_fixture(scope, "10.8.0.0/16", %{status: "container"})
    v6_empty = prefix_fixture(scope, "2001:db8:f::/48", %{status: "container"})
    active_parent = prefix_fixture(scope, "10.9.0.0/16")
    prefix_fixture(scope, "10.9.1.0/24")
    {_host, ports} = device_fixture(scope, "server", "status-usage", ~w(eth0))
    address_fixture(scope, ports["eth0"], "10.9.1.5")
    address_fixture(scope, ports["eth0"], "10.9.200.5")

    %{ipv4: ipv4, ipv6: ipv6} = IPAM.list_prefix_rows(scope, nil)
    usage = fn rows, prefix -> Enum.find(rows, &(&1.node.prefix.id == prefix.id)).usage end

    # An empty container has nothing allocated, one octet deeper.
    assert usage.(ipv4, empty) ==
             %{kind: :children, allocated: 0, total: 256, level: 24, level_name: nil}

    assert usage.(ipv6, v6_empty) ==
             %{kind: :children, allocated: 0, total: 256, level: 56, level_name: nil}

    # An active parent counts its hosts, inside children or not, though it is
    # still shown as child space.
    assert usage.(ipv4, active_parent) == %{kind: :count, count: 2}
    assert IPAM.prefix_view(scope, active_parent).mode == :container
  end

  test "managed addresses occupy space alongside observed hosts, each host once", %{
    scope: scope
  } do
    lan = prefix_fixture(scope, "192.0.2.0/28")
    blue_lan = prefix_fixture(scope, "192.0.2.0/28", %{vrf: "blue"})
    {_host, ports} = device_fixture(scope, "server", "occupancy", ~w(eth0 eth1))
    observed = address_fixture(scope, ports["eth0"], "192.0.2.5/28")
    address_fixture(scope, ports["eth1"], "192.0.2.5/28")
    {:ok, _} = IPAM.adopt_address(scope, observed.id)
    {:ok, _} = IPAM.create_ip_address(scope, %{address: "192.0.2.9/28"})
    {:ok, retired} = IPAM.create_ip_address(scope, %{address: "192.0.2.10/28"})
    {:ok, _} = IPAM.release_address(scope, retired.id)
    {:ok, _} = IPAM.create_ip_address(scope, %{address: "192.0.2.0/28"})

    {:ok, _} =
      IPAM.create_ip_address(scope, %{address: "192.0.2.3/28", vrf_id: blue_lan.vrf_id})

    usage = fn rows, prefix -> Enum.find(rows.ipv4, &(&1.node.prefix.id == prefix.id)).usage end

    # .5 is observed twice and managed, .9 is reserved: two hosts. The
    # released .10 is history and the network address .0 is not assignable.
    assert %{used: 2, usable: 14} = usage.(IPAM.list_prefix_rows(scope, nil), lan)
    assert %{used: 2, managed_unseen: 1} = IPAM.prefix_view(scope, lan).address_map

    # In the VRF only its own managed address counts.
    assert %{used: 1} = usage.(IPAM.list_prefix_rows(scope, blue_lan.vrf_id), blue_lan)

    blue_view = IPAM.prefix_view(scope, IPAM.get_prefix!(scope, blue_lan.id))
    assert %{used: 1, managed_unseen: 1} = blue_view.address_map
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
