defmodule RengaWeb.TopologyLiveTest do
  use RengaWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Renga.AccountsFixtures
  import Renga.InventoryFixtures
  import Renga.TopologyFixtures

  alias Renga.Accounts
  alias Renga.Inventory
  alias Renga.Topology
  alias Renga.Topology.Links

  setup %{conn: conn} do
    user = user_fixture()
    organization = organization_fixture()
    organization_membership_fixture(user, organization, %{role: "admin"})
    scope = Accounts.scope_for_user(user, organization.id)

    conn =
      conn
      |> log_in_user(user)
      |> put_session(:current_organization_id, organization.id)

    %{conn: conn, organization: organization, scope: scope}
  end

  test "draws each link with how its plan, evidence, and cable record agree", %{
    conn: conn,
    scope: scope
  } do
    net = network(scope)

    {:ok, view, _html} = live(conn, ~p"/network/topology")

    assert has_element?(view, "#topology-legend-agreeing", "1")
    assert has_element?(view, "#link-#{net.agreeing}[data-list-row]")
    assert has_element?(view, "#link-#{net.agreeing} [data-link-state='agreeing']")
    assert has_element?(view, "#link-#{net.unrecorded} [data-link-state='unrecorded']")
    assert has_element?(view, "#link-#{net.planned} [data-link-state='planned']")

    # Devices sit in tiers; links between two devices share one edge whose
    # state is the most urgent of them.
    assert has_element?(view, "#topology-map-tier-switches")
    assert has_element?(view, "#topology-map-tier-devices")
    assert has_element?(view, "#topology-map-node-#{net.leaf.id}")

    assert has_element?(
             view,
             "#topology-map-edge-#{edge_id(net.host, net.leaf)}[data-edge-state='unrecorded']"
           )
  end

  test "keeps unresolved neighbors and logical relationships apart from links", %{
    conn: conn,
    scope: scope
  } do
    context = legacy_context(scope)

    {:ok, view, _html} = live(conn, ~p"/network/topology")

    assert has_element?(
             view,
             "#logical-relationships #relationship-#{context.relationship.id}[data-relationship-kind='bridge_member']"
           )

    assert has_element?(
             view,
             "#neighbor-evidence #neighbor-evidence-#{context.unresolved.id}[data-evidence-protocol='lldp']"
           )

    assert has_element?(view, "#neighbor-evidence-#{context.unresolved.id}", "ghost-switch:swp9")

    key = Links.key(context.local.id, context.remote.id)
    assert has_element?(view, "#topology-links #link-#{key} [data-link-state='unrecorded']")
    refute has_element?(view, "#topology-links #neighbor-evidence-#{context.unresolved.id}")
  end

  test "selecting a link shows plan, evidence, and cable record side by side", %{
    conn: conn,
    scope: scope
  } do
    net = network(scope)

    {:ok, view, _html} = live(conn, ~p"/network/topology")

    view |> element("#link-#{net.agreeing}-open") |> render_click()
    assert_patch(view, ~p"/network/topology?#{[link: net.agreeing]}")

    assert has_element?(view, "#link-panel")
    assert has_element?(view, "#link-plan[data-present='false']", "Not planned")
    assert has_element?(view, "#link-evidence[data-present='true']", "LLDP")
    assert has_element?(view, "#link-cable[data-present='true']", "by an operator")
    assert has_element?(view, "#retract-cable")
    refute has_element?(view, "#record-cable")

    # The map edge opens the same panel.
    view |> element("#topology-map-edge-#{edge_id(net.host, net.leaf)}") |> render_click()
    assert_patch(view, ~p"/network/topology?#{[link: net.unrecorded]}")
    assert has_element?(view, "#link-cable[data-present='false']", "Not recorded")
  end

  test "names the competing claim when layers disagree", %{conn: conn, scope: scope} do
    {host, host_ports} = device_fixture(scope, "server", "drift-host", ~w(eth0))
    {leaf, leaf_ports} = device_fixture(scope, "switch", "drift-leaf", ~w(swp1 swp2))
    cable_plan_fixture(scope, host_ports["eth0"], leaf_ports["swp1"])
    report_neighbors(scope, host, %{"eth0" => {leaf.name, "swp2"}})

    planned = Links.key(host_ports["eth0"].id, leaf_ports["swp1"].id)
    seen = Links.key(host_ports["eth0"].id, leaf_ports["swp2"].id)

    {:ok, view, _html} = live(conn, ~p"/network/topology?#{[link: planned]}")

    assert has_element?(view, "#link-panel-state[data-link-state='disagreeing']")
    assert has_element?(view, "#link-contested", "by the evidence")
    assert has_element?(view, "#topology-map-edge-#{edge_id(host, leaf)} rect.fill-warn")

    view |> element("#contest-#{seen}") |> render_click()
    assert_patch(view, ~p"/network/topology?#{[link: seen]}")
    assert has_element?(view, "#link-plan[data-present='false']")
    assert has_element?(view, "#link-evidence[data-present='true']")
  end

  test "records and retracts a cable only by explicit operator assertion", %{
    conn: conn,
    scope: scope
  } do
    net = network(scope)

    {:ok, view, _html} = live(conn, ~p"/network/topology?#{[link: net.unrecorded]}")

    assert has_element?(view, "#record-cable-confirm", "You confirm that a cable connects")
    view |> element("#record-cable-confirm-confirm") |> render_click()

    assert has_element?(view, "#flash-info", "Cable recorded")
    assert has_element?(view, "#link-panel-state[data-link-state='agreeing']")
    assert %Links{state: :agreeing} = Topology.get_link(scope, net.unrecorded)

    view |> element("#retract-cable-confirm-confirm") |> render_click()

    assert has_element?(view, "#flash-info", "Cable retracted")
    assert %Links{state: :unrecorded, cable: nil} = Topology.get_link(scope, net.unrecorded)
  end

  test "warns before a recorded cable is displaced", %{conn: conn, scope: scope} do
    {host, host_ports} = device_fixture(scope, "server", "move-host", ~w(eth0))
    {leaf, leaf_ports} = device_fixture(scope, "switch", "move-leaf", ~w(swp1 swp2))
    cable_fixture(scope, host_ports["eth0"], leaf_ports["swp1"])
    report_neighbors(scope, host, %{"eth0" => {leaf.name, "swp2"}})

    seen = Links.key(host_ports["eth0"].id, leaf_ports["swp2"].id)
    {:ok, view, _html} = live(conn, ~p"/network/topology?#{[link: seen]}")

    assert has_element?(view, "#record-cable-confirm", "This replaces the recorded cable")
  end

  test "members read links without cable actions", %{organization: organization, scope: scope} do
    net = network(scope)
    member = user_fixture()
    organization_membership_fixture(member, organization, %{role: "member"})

    member_conn =
      build_conn()
      |> log_in_user(member)
      |> put_session(:current_organization_id, organization.id)

    {:ok, view, _html} = live(member_conn, ~p"/network/topology?#{[link: net.unrecorded]}")

    assert has_element?(view, "#link-panel")
    refute has_element?(view, "#record-cable")
    refute has_element?(view, "#record-cable-confirm")
  end

  test "focuses the map and table on one device", %{conn: conn, scope: scope} do
    net = network(scope)
    {other, other_ports} = device_fixture(scope, "server", "other-host", ~w(eth0))
    cable_fixture(scope, other_ports["eth0"], net.leaf_ports["swp4"])

    {:ok, view, _html} = live(conn, ~p"/network/topology")
    assert has_element?(view, "#topology-map-node-#{other.id}")

    view |> element("#topology-map-node-#{net.host.id}") |> render_click()
    assert_patch(view, ~p"/network/topology?#{[resource: net.host.id]}")

    assert has_element?(view, "#topology-focus", net.host.name)
    assert has_element?(view, "#topology-map-node-#{net.host.id}[data-focused='true']")
    refute has_element?(view, "#topology-map-node-#{other.id}")

    refute has_element?(
             view,
             "#link-#{Links.key(other_ports["eth0"].id, net.leaf_ports["swp4"].id)}"
           )

    view |> element("#topology-clear-focus") |> render_click()
    assert_patch(view, ~p"/network/topology")
    assert has_element?(view, "#topology-map-node-#{other.id}")
  end

  test "filters every section by one interface", %{conn: conn, scope: scope} do
    context = legacy_context(scope)
    other = legacy_context(scope, tag: "other")

    {:ok, view, _html} = live(conn, ~p"/network/topology?#{[interface_id: context.local.id]}")

    assert has_element?(view, "#topology-clear-interface")
    assert has_element?(view, "#relationship-#{context.relationship.id}")
    assert has_element?(view, "#link-#{Links.key(context.local.id, context.remote.id)}")
    assert has_element?(view, "#neighbor-evidence-#{context.unresolved.id}")

    refute has_element?(view, "#relationship-#{other.relationship.id}")
    refute has_element?(view, "#link-#{Links.key(other.local.id, other.remote.id)}")
    refute has_element?(view, "#neighbor-evidence-#{other.unresolved.id}")
  end

  test "updates when cabling changes elsewhere", %{conn: conn, scope: scope} do
    net = network(scope)
    {:ok, view, _html} = live(conn, ~p"/network/topology")

    assert has_element?(view, "#link-#{net.unrecorded} [data-link-state='unrecorded']")
    cable_fixture(scope, net.host_ports["eth1"], net.leaf_ports["swp2"])

    traffic =
      Task.async(fn ->
        for _ <- 1..15 do
          send(view.pid, {:inventory_changed, scope.organization_id})
          Process.sleep(100)
        end
      end)

    assert eventually(fn ->
             has_element?(view, "#link-#{net.unrecorded} [data-link-state='agreeing']")
           end)

    Task.await(traffic)
  end

  test "all focused links remain selectable beyond the map and former table limits", %{
    conn: conn,
    scope: scope
  } do
    names = Enum.map(1..201, &"swp#{&1}")
    {a, a_ports} = device_fixture(scope, "switch", "a", names)
    {_b, b_ports} = device_fixture(scope, "switch", "b", names)
    for name <- names, do: cable_fixture(scope, a_ports[name], b_ports[name])
    last = scope |> Topology.list_links() |> List.last()
    {:ok, view, _} = live(conn, ~p"/network/topology?#{[resource: a.id]}")
    assert has_element?(view, "#link-#{last.key}-open")
    view |> element("#link-#{last.key}-open") |> render_click()
    assert has_element?(view, "#link-cable[data-present=true]")
  end

  test "keeps another organization's topology invisible", %{conn: conn, scope: scope} do
    context = legacy_context(scope)

    foreign_user = user_fixture()
    foreign_organization = organization_fixture()
    organization_membership_fixture(foreign_user, foreign_organization, %{role: "admin"})
    foreign_scope = Accounts.scope_for_user(foreign_user, foreign_organization.id)
    foreign = legacy_context(foreign_scope, tag: "foreign")
    foreign_key = Links.key(foreign.local.id, foreign.remote.id)

    {:ok, view, _html} = live(conn, ~p"/network/topology?#{[link: foreign_key]}")

    assert has_element?(view, "#relationship-#{context.relationship.id}")
    assert has_element?(view, "#neighbor-evidence-#{context.unresolved.id}")
    refute has_element?(view, "#relationship-#{foreign.relationship.id}")
    refute has_element?(view, "#neighbor-evidence-#{foreign.unresolved.id}")
    refute has_element?(view, "#link-#{foreign_key}")
    refute has_element?(view, "#link-panel")
  end

  test "shows an empty map without links", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/network/topology")

    assert has_element?(view, "#topology-map-empty")
    refute has_element?(view, "#topology-map")
  end

  test "requires authentication" do
    assert {:error, {:redirect, %{to: path}}} = live(build_conn(), ~p"/network/topology")
    assert path =~ "/users/log-in"
  end

  # A leaf switch with one host: eth0 is cabled and seen (agreeing), eth1 is
  # seen but not recorded, and eth2 is planned only.
  defp network(scope) do
    suffix = System.unique_integer([:positive])

    {leaf, leaf_ports} =
      device_fixture(scope, "switch", "leaf-#{suffix}", ~w(swp1 swp2 swp3 swp4))

    {host, host_ports} = device_fixture(scope, "server", "host-#{suffix}", ~w(eth0 eth1 eth2))

    report_neighbors(scope, host, %{
      "eth0" => {leaf.name, "swp1"},
      "eth1" => {leaf.name, "swp2"}
    })

    cable_fixture(scope, host_ports["eth0"], leaf_ports["swp1"])
    cable_plan_fixture(scope, host_ports["eth2"], leaf_ports["swp3"])

    %{
      leaf: leaf,
      host: host,
      leaf_ports: leaf_ports,
      host_ports: host_ports,
      agreeing: Links.key(host_ports["eth0"].id, leaf_ports["swp1"].id),
      unrecorded: Links.key(host_ports["eth1"].id, leaf_ports["swp2"].id),
      planned: Links.key(host_ports["eth2"].id, leaf_ports["swp3"].id)
    }
  end

  defp edge_id(first, second) do
    [a, b] = Enum.sort([first.id, second.id])
    "#{a}_#{b}"
  end

  defp eventually(check, attempts \\ 20) do
    cond do
      check.() -> true
      attempts == 0 -> false
      true -> Process.sleep(50) && eventually(check, attempts - 1)
    end
  end

  # A server with a bridge relationship, a matched LLDP neighbor, and an
  # unmatched one, as collectors report them.
  defp legacy_context(scope, opts \\ []) do
    tag = Keyword.get(opts, :tag, "topology-ui")
    suffix = System.unique_integer([:positive])

    {:ok, local_resource} =
      Inventory.create_resource(scope, %{
        kind: "server",
        name: "#{tag}-local-#{suffix}",
        lifecycle_state: "active"
      })

    {:ok, remote_resource} =
      Inventory.create_resource(scope, %{
        kind: "switch",
        name: "#{tag}-remote-#{suffix}",
        lifecycle_state: "active"
      })

    {:ok, local} = Inventory.create_interface(scope, local_resource.id, %{name: "eth0"})

    {:ok, bridge} =
      Inventory.create_interface(scope, local_resource.id, %{name: "br0", kind: "bridge"})

    {:ok, remote} = Inventory.create_interface(scope, remote_resource.id, %{name: "swp1"})

    {:ok, relationship} =
      Inventory.create_interface_relationship(scope, local.id, bridge.id, %{kind: "bridge_member"})

    evidence =
      report_neighbors(scope, local_resource, %{
        "eth0" => [{remote_resource.name, remote.name}, {"ghost-switch", "swp9"}]
      })

    [unresolved] =
      Enum.reject(
        evidence,
        &(Topology.get_interface_neighbor_match(scope, &1.id).status == "matched")
      )

    %{local: local, remote: remote, relationship: relationship, unresolved: unresolved}
  end
end
