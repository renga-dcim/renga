defmodule RengaWeb.ResourcePortsLiveTest do
  use RengaWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Renga.AccountsFixtures
  import Renga.InventoryFixtures
  import Renga.TopologyFixtures

  alias Renga.Accounts
  alias Renga.Topology.Links

  setup %{conn: conn} do
    user = user_fixture()
    organization = organization_fixture()
    organization_membership_fixture(user, organization, %{role: "member"})

    admin = user_fixture()
    organization_membership_fixture(admin, organization, %{role: "admin"})
    admin_scope = Accounts.scope_for_user(admin, organization.id)

    conn =
      conn
      |> log_in_user(user)
      |> put_session(:current_organization_id, organization.id)

    %{conn: conn, scope: admin_scope}
  end

  # A leaf with an agreeing uplink on swp1 carrying a drifting trunk, a
  # down access port on swp2, and an unreported swp10.
  defp switch(scope) do
    group = vlan_group_fixture(scope, "ports-ui-#{System.unique_integer([:positive])}")
    users = vlan_fixture(scope, group, 10, "users")
    voice = vlan_fixture(scope, group, 20, "voice")
    vlan_fixture(scope, group, 30, "storage")

    {leaf, ports} =
      device_fixture(scope, "switch", "leaf-#{System.unique_integer([:positive])}", [
        {"swp10", %{}},
        {"swp1", %{status: "up", speed_mbps: 25_000}},
        {"swp2", %{status: "down", speed_mbps: 1000}}
      ])

    {host, host_ports} = device_fixture(scope, "server", "host-#{leaf.name}", ~w(eth0))
    cable_fixture(scope, ports["swp1"], host_ports["eth0"], %{label: "A-17"})
    report_neighbors(scope, leaf, %{"swp1" => {host.name, "eth0"}})

    desire_vlans(scope, ports["swp1"], "trunk", users, [voice])
    desire_vlans(scope, ports["swp2"], "access", users)

    report_vlans(scope, leaf, group, %{
      "swp1" => {"trunk", [{10, "untagged"}, {20, "tagged"}, {30, "tagged"}]},
      "swp2" => {"access", [{10, "untagged"}]}
    })

    %{leaf: leaf, ports: ports, host: host, host_ports: host_ports}
  end

  test "shows the front panel and port table in natural order", %{conn: conn, scope: scope} do
    s = switch(scope)
    swp1 = s.ports["swp1"].id

    {:ok, view, _html} = live(conn, ~p"/inventory/#{s.leaf}/ports")

    assert has_element?(view, "#resource-detail-tabs a[aria-current=page]", "Ports")
    assert has_element?(view, "#ports-summary", "3")
    assert has_element?(view, "#panel-port-#{swp1}[data-status='up'][data-drift='true']")
    assert has_element?(view, "#panel-port-#{s.ports["swp2"].id}[data-status='down']")
    assert has_element?(view, "#panel-port-#{s.ports["swp10"].id}[data-status='unknown']")

    rows = view |> render() |> LazyHTML.from_fragment() |> LazyHTML.query("#ports tbody tr")

    assert Enum.map(rows, &(&1 |> LazyHTML.attribute("id") |> hd())) ==
             Enum.map(~w(swp1 swp2 swp10), &"port-#{s.ports[&1].id}")

    assert has_element?(view, "#port-#{swp1}", "25G")
    assert has_element?(view, "#port-#{swp1}", "Trunk")
    assert has_element?(view, "#port-#{swp1}", "20, 30")
    assert has_element?(view, "#port-#{swp1}", "A-17")

    key = Links.key(swp1, s.host_ports["eth0"].id)
    assert has_element?(view, "#port-#{swp1} a[href='/network/topology?link=#{key}']", "eth0")
    assert has_element?(view, "#port-#{swp1}-drift", "VLAN drift")
    refute has_element?(view, "#port-#{s.ports["swp2"].id}-drift")
  end

  test "expands a drifting port in place with desired and observed membership", %{
    conn: conn,
    scope: scope
  } do
    s = switch(scope)
    swp1 = s.ports["swp1"].id

    {:ok, view, _html} = live(conn, ~p"/inventory/#{s.leaf}/ports")
    refute has_element?(view, "#port-#{swp1}-details")

    view |> element("#port-#{swp1}-drift") |> render_click()
    assert_patch(view, ~p"/inventory/#{s.leaf}/ports?#{[port: swp1]}")

    assert has_element?(view, "#port-#{swp1}-details")
    assert has_element?(view, "#port-#{swp1}-membership [data-vlan='30'][data-flag='unexpected']")
    assert has_element?(view, "#port-#{swp1}-membership [data-vlan='20']:not([data-flag])")
    assert has_element?(view, "#port-#{swp1}-details", "VLAN 30:")
    assert has_element?(view, "#port-#{swp1}-details", "Observed VLAN is not desired")
    assert has_element?(view, "#port-#{swp1}-details a[href*='interface_id=#{swp1}']")

    # Selecting it again closes it.
    view |> element("#port-#{swp1}-open") |> render_click()
    assert_patch(view, ~p"/inventory/#{s.leaf}/ports")
    refute has_element?(view, "#port-#{swp1}-details")
  end

  test "selecting a port on the front panel opens its row", %{conn: conn, scope: scope} do
    s = switch(scope)
    swp2 = s.ports["swp2"].id

    {:ok, view, _html} = live(conn, ~p"/inventory/#{s.leaf}/ports")
    view |> element("#panel-port-#{swp2}") |> render_click()

    assert_patch(view, ~p"/inventory/#{s.leaf}/ports?#{[port: swp2]}")
    assert has_element?(view, "#panel-port-#{swp2}[aria-pressed='true']")
    assert has_element?(view, "#port-#{swp2}[aria-current='true']")
    assert has_element?(view, "#port-#{swp2}-details", "Access")
  end

  test "only switches have a Ports tab", %{conn: conn, scope: scope} do
    s = switch(scope)

    {:ok, view, _html} = live(conn, ~p"/inventory/#{s.leaf}")
    assert has_element?(view, "#resource-detail-tabs a[href='/inventory/#{s.leaf.id}/ports']")

    {:ok, host_view, _html} = live(conn, ~p"/inventory/#{s.host}")
    refute has_element?(host_view, "#resource-detail-tabs a", "Ports")

    assert {:error, {:live_redirect, %{to: path}}} = live(conn, ~p"/inventory/#{s.host}/ports")
    assert path == "/inventory/#{s.host.id}/network"
  end

  test "shows an empty state for a switch without ports", %{conn: conn, scope: scope} do
    {leaf, _ports} = device_fixture(scope, "switch", "bare-leaf", [])

    {:ok, view, _html} = live(conn, ~p"/inventory/#{leaf}/ports")
    assert has_element?(view, "#ports-empty")
    refute has_element?(view, "#front-panel")
  end

  test "refreshes ports while organization notifications keep arriving", %{
    conn: conn,
    scope: scope
  } do
    {leaf, _ports} = device_fixture(scope, "switch", "busy-leaf", [])
    {:ok, view, _} = live(conn, ~p"/inventory/#{leaf}/ports")
    {:ok, port} = Renga.Inventory.create_interface(scope, leaf.id, %{name: "swp1", status: "up"})

    for _ <- 1..7 do
      send(view.pid, {:inventory_changed, scope.organization_id})
      Process.sleep(100)
    end

    assert has_element?(view, "#panel-port-#{port.id}[data-status=up]")
    refute has_element?(view, "#ports-empty")
  end

  test "keeps another organization's switch out of reach", %{conn: conn} do
    other = user_fixture()
    other_organization = organization_fixture()
    organization_membership_fixture(other, other_organization, %{role: "admin"})
    other_scope = Accounts.scope_for_user(other, other_organization.id)
    {leaf, _ports} = device_fixture(other_scope, "switch", "foreign-leaf", ~w(swp1))

    assert_raise Ecto.NoResultsError, fn -> live(conn, ~p"/inventory/#{leaf}/ports") end
  end
end
