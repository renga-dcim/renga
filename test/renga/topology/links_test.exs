defmodule Renga.Topology.LinksTest do
  use Renga.DataCase, async: true

  import Renga.AccountsFixtures
  import Renga.InventoryFixtures
  import Renga.TopologyFixtures

  alias Renga.Accounts
  alias Renga.Inventory.Interface
  alias Renga.Inventory.Resource
  alias Renga.Topology
  alias Renga.Topology.Cable
  alias Renga.Topology.CablePlan
  alias Renga.Topology.CurrentInterfaceAdjacency
  alias Renga.Topology.LinkMap
  alias Renga.Topology.Links

  describe "build/3" do
    setup do
      server = resource("server", "db-1")
      leaf = resource("switch", "leaf-1")

      %{
        eth0: interface(server, "eth0"),
        eth1: interface(server, "eth1"),
        swp1: interface(leaf, "swp1"),
        swp2: interface(leaf, "swp2")
      }
    end

    test "states each pair by which layers agree on it", ctx do
      links =
        Links.build(
          [record(CablePlan, ctx.eth1, ctx.swp2)],
          [record(Cable, ctx.eth0, ctx.swp1)],
          [record(CurrentInterfaceAdjacency, ctx.swp1, ctx.eth0)]
        )

      assert [
               %Links{state: :planned, plan: %CablePlan{}, cable: nil, adjacency: nil},
               %Links{state: :agreeing, cable: %Cable{}, adjacency: %CurrentInterfaceAdjacency{}}
             ] = links

      assert Links.counts(links) == %{
               disagreeing: 0,
               unrecorded: 0,
               planned: 1,
               recorded: 0,
               agreeing: 1
             }

      assert [state: :unrecorded] ==
               Links.build([], [], [record(CurrentInterfaceAdjacency, ctx.eth0, ctx.swp1)])
               |> Enum.map(&{:state, &1.state})

      assert [%Links{state: :recorded}] = Links.build([], [record(Cable, ctx.eth0, ctx.swp1)], [])
    end

    test "marks both links when layers send one endpoint to different neighbors", ctx do
      links =
        Links.build(
          [record(CablePlan, ctx.eth0, ctx.swp1)],
          [],
          [record(CurrentInterfaceAdjacency, ctx.eth0, ctx.swp2)]
        )

      assert Enum.map(links, & &1.state) == [:disagreeing, :disagreeing]

      planned = Enum.find(links, & &1.plan)
      assert [%{interface: eth0, other: swp2, layers: [:evidence]}] = planned.contested
      assert eth0.id == ctx.eth0.id
      assert swp2.id == ctx.swp2.id
    end

    test "keys are independent of endpoint order and round-trip", ctx do
      key = Links.key(ctx.swp1.id, ctx.eth0.id)

      assert key == Links.key(ctx.eth0.id, ctx.swp1.id)
      assert {:ok, {a, b}} = Links.parse_key(key)
      assert a < b
      assert Links.parse_key("#{ctx.eth0.id}_#{ctx.eth0.id}") == :error
      assert Links.parse_key("not-a-key") == :error
      assert Links.parse_key(nil) == :error
    end

    test "filters by interface or resource", ctx do
      links =
        Links.build(
          [record(CablePlan, ctx.eth1, ctx.swp2)],
          [record(Cable, ctx.eth0, ctx.swp1)],
          []
        )

      assert [%{plan: %CablePlan{}}] = Links.filter(links, interface_id: ctx.swp2.id)
      assert length(Links.filter(links, resource_id: ctx.eth0.resource_id)) == 2
      assert length(Links.filter(links, [])) == 2
    end
  end

  describe "LinkMap.build/2" do
    test "puts spine switches above leaf switches above devices" do
      spine = resource("switch", "spine-1")
      leaf_a = resource("switch", "leaf-a")
      leaf_b = resource("switch", "leaf-b")
      host_b = resource("server", "host-b")
      host_a = resource("server", "host-a")

      links =
        Links.build(
          [],
          [
            record(Cable, interface(spine, "swp1"), interface(leaf_a, "swp49")),
            record(Cable, interface(spine, "swp2"), interface(leaf_b, "swp49")),
            record(Cable, interface(leaf_b, "swp1"), interface(host_b, "eth0")),
            record(Cable, interface(leaf_a, "swp1"), interface(host_a, "eth0"))
          ],
          []
        )

      map = LinkMap.build(links)

      assert Enum.map(map.tiers, &{&1.id, Enum.map(&1.nodes, fn node -> node.name end)}) == [
               spine: ["spine-1"],
               leaf: ["leaf-a", "leaf-b"],
               # Hosts sit under the leaf they hang off, not alphabetically.
               devices: ["host-a", "host-b"]
             ]

      assert length(map.edges) == 4
      assert map.hidden == 0
    end

    test "bundles links between two devices into one edge with the most urgent state" do
      leaf = resource("switch", "leaf-1")
      host = resource("server", "host-1")
      eth0 = interface(host, "eth0")
      swp1 = interface(leaf, "swp1")
      swp2 = interface(leaf, "swp2")

      links =
        Links.build(
          [record(CablePlan, interface(host, "eth1"), interface(leaf, "swp3"))],
          [record(Cable, eth0, swp1)],
          [record(CurrentInterfaceAdjacency, eth0, swp2)]
        )

      assert [%{state: :disagreeing, link_keys: keys, primary: primary}] =
               LinkMap.build(links).edges

      assert length(keys) == 3
      assert primary in [Links.key(eth0.id, swp1.id), Links.key(eth0.id, swp2.id)]
    end

    test "draws at most max_nodes devices, keeping switches and the focus" do
      leaf = resource("switch", "leaf-1")
      hosts = for n <- 1..4, do: resource("server", "host-#{n}")

      links =
        Links.build(
          [],
          for({host, n} <- Enum.with_index(hosts, 1)) do
            record(Cable, interface(leaf, "swp#{n}"), interface(host, "eth0"))
          end,
          []
        )

      focus = List.last(hosts)
      map = LinkMap.build(links, max_nodes: 2, focus: focus.id)
      drawn = Enum.flat_map(map.tiers, & &1.nodes)

      assert map.hidden == 3
      assert Enum.map(drawn, & &1.id) |> Enum.sort() == Enum.sort([leaf.id, focus.id])
      assert [%{b: b, a: a}] = map.edges
      assert focus.id in [a, b]
    end
  end

  describe "Topology.list_links/1 and get_link/2" do
    setup do
      user = user_fixture()
      organization = organization_fixture()
      organization_membership_fixture(user, organization, %{role: "admin"})
      %{scope: Accounts.scope_for_user(user, organization.id)}
    end

    test "joins plans, evidence, and cables loaded from the organization", %{scope: scope} do
      {host, host_ports} = device_fixture(scope, "server", "links-host", ~w(eth0 eth1))
      {leaf, leaf_ports} = device_fixture(scope, "switch", "links-leaf", ~w(swp1 swp2))

      report_neighbors(scope, host, %{"eth0" => {leaf.name, "swp1"}})
      cable_fixture(scope, host_ports["eth0"], leaf_ports["swp1"])
      cable_plan_fixture(scope, host_ports["eth1"], leaf_ports["swp2"])

      assert [planned, agreeing] = Topology.list_links(scope)
      assert planned.state == :planned
      assert agreeing.state == :agreeing
      assert agreeing.interface_a.resource.name in ["links-host", "links-leaf"]

      key = Links.key(leaf_ports["swp1"].id, host_ports["eth0"].id)
      assert %Links{state: :agreeing, key: ^key} = Topology.get_link(scope, key)

      # A link is found from a key in either endpoint order.
      [first, second] = String.split(key, "_")
      assert %Links{key: ^key} = Topology.get_link(scope, "#{second}_#{first}")

      assert Topology.get_link(scope, Links.key(host_ports["eth1"].id, leaf_ports["swp1"].id)) ==
               nil

      assert Topology.get_link(scope, "garbage") == nil
    end

    test "never shows another organization's links", %{scope: scope} do
      {_host, host_ports} = device_fixture(scope, "server", "own-host", ~w(eth0))
      {_leaf, leaf_ports} = device_fixture(scope, "switch", "own-leaf", ~w(swp1))
      cable_fixture(scope, host_ports["eth0"], leaf_ports["swp1"])

      other = user_fixture()
      other_organization = organization_fixture()
      organization_membership_fixture(other, other_organization, %{role: "admin"})
      other_scope = Accounts.scope_for_user(other, other_organization.id)

      assert Topology.list_links(other_scope) == []

      key = Links.key(host_ports["eth0"].id, leaf_ports["swp1"].id)
      assert Topology.get_link(other_scope, key) == nil
    end
  end

  defp resource(kind, name), do: %Resource{id: Ecto.UUID.generate(), kind: kind, name: name}

  defp interface(resource, name) do
    %Interface{
      id: Ecto.UUID.generate(),
      name: name,
      kind: "ethernet",
      resource_id: resource.id,
      resource: resource
    }
  end

  defp record(schema, first, second) do
    {a, b} = if first.id <= second.id, do: {first, second}, else: {second, first}

    struct(schema,
      id: Ecto.UUID.generate(),
      interface_a_id: a.id,
      interface_b_id: b.id,
      interface_a: a,
      interface_b: b
    )
  end
end
