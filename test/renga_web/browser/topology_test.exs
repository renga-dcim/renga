defmodule RengaWeb.Browser.TopologyTest do
  @moduledoc """
  The topology map in a real browser: edges drawn between the devices they
  join, an edge opened from the keyboard, a cable recorded from evidence by
  explicit assertion, and the page staying usable at phone width.
  """
  use PhoenixTest.Playwright.Case, async: true

  import Renga.AccountsFixtures
  import Renga.InventoryFixtures
  import Renga.TopologyFixtures

  alias Renga.Topology.Links

  @moduletag :playwright

  setup %{conn: conn} do
    organization = organization_fixture()
    user = user_fixture()
    organization_membership_fixture(user, organization, %{role: "admin"})
    scope = Renga.Accounts.scope_for_user(user, organization.id)

    {spine, spine_ports} = device_fixture(scope, "switch", "spine-01", ~w(swp1 swp2))
    {leaf, leaf_ports} = device_fixture(scope, "switch", "leaf-01", ~w(swp1 swp2 swp49))
    {host, host_ports} = device_fixture(scope, "server", "web-01", ~w(eth0 eth1))

    cable_fixture(scope, spine_ports["swp1"], leaf_ports["swp49"])
    report_neighbors(scope, host, %{"eth0" => {leaf.name, "swp1"}})
    cable_plan_fixture(scope, host_ports["eth1"], leaf_ports["swp2"])

    conn =
      add_session_cookie(
        conn,
        [
          value: %{
            user_token: Renga.Accounts.generate_user_session_token(user),
            current_organization_id: organization.id
          }
        ],
        RengaWeb.Endpoint.session_options()
      )

    %{
      conn: conn,
      scope: scope,
      spine: spine,
      leaf: leaf,
      host: host,
      seen: Links.key(host_ports["eth0"].id, leaf_ports["swp1"].id)
    }
  end

  test "draws tiers and opens a link from the keyboard to record its cable", context do
    edge = "#topology-map-edge-#{edge_id(context.leaf, context.host)}"

    context.conn
    |> visit("/network/topology")
    |> assert_has("body .phx-connected")
    |> assert_has("#topology-map-tier-spine", text: "Spine switches")
    |> assert_has("#topology-map-tier-leaf", text: "Leaf switches")
    |> assert_has("#{edge}[data-edge-state='unrecorded']")
    |> evaluate(edge_between_js(edge, context.leaf, context.host), &assert(&1 == true))
    |> press(edge, "Enter")
    |> assert_has("#link-panel [role=dialog]")
    |> assert_has("#link-evidence[data-present='true']")
    |> assert_has("#link-cable[data-present='false']")
    |> click_button("#record-cable", "Record this cable")
    |> assert_has("#record-cable-confirm [role=alertdialog]", text: "You confirm that a cable")
    |> click_button("#record-cable-confirm-confirm", "Record cable")
    |> assert_has("#link-panel-state[data-link-state='agreeing']")
    |> assert_has("#{edge}[data-edge-state='planned']")
  end

  test "long same-tier bundles fit inside the map canvas", context do
    devices =
      Map.new(~w(a b c d e f g h), fn name ->
        {name, device_fixture(context.scope, "switch", name, ~w(swp1 swp2))}
      end)

    for {a, b} <- [{"a", "h"}, {"b", "c"}, {"d", "e"}, {"f", "g"}] do
      {_, a_ports} = devices[a]
      {_, b_ports} = devices[b]
      cable_fixture(context.scope, a_ports["swp1"], b_ports["swp1"])
    end

    {a, a_ports} = devices["a"]
    {h, h_ports} = devices["h"]
    cable_fixture(context.scope, a_ports["swp2"], h_ports["swp2"])
    edge = "topology-map-edge-#{edge_id(a, h)}"

    context.conn
    |> visit("/network/topology")
    |> assert_has("body .phx-connected")
    |> evaluate(
      """
      (() => {
        const edge = document.getElementById('#{edge}');
        const box = edge.getBBox(), canvas = edge.ownerSVGElement.viewBox.baseVal;
        return {count: edge.querySelector('text').textContent.trim(),
          inside: box.y >= 0 && box.x >= 0 && box.y + box.height <= canvas.height && box.x + box.width <= canvas.width};
      })()
      """,
      fn result -> assert result == %{"count" => "2", "inside" => true} end
    )
  end

  @tag browser_context_opts: [
         has_touch: true,
         is_mobile: true,
         viewport: %{width: 390, height: 844}
       ]
  test "keeps the page within a phone screen and links tappable", context do
    context.conn
    |> visit("/network/topology")
    |> assert_has("body .phx-connected")
    |> assert_has("#topology-map")
    |> evaluate(fits_width_js(), &assert(&1 == true))
    |> evaluate(open_heights_js(), fn heights ->
      assert heights != []
      assert Enum.all?(heights, &(round(&1) >= 44))
    end)
    |> click_link("#link-#{context.seen}-open", "Seen, not recorded")
    |> assert_has("#link-panel [role=dialog]")
    |> assert_has("#record-cable")
  end

  defp edge_id(first, second) do
    [a, b] = Enum.sort([first.id, second.id])
    "#{a}_#{b}"
  end

  # The edge's visible line starts at the bottom of the upper device and
  # ends at the top of the lower one.
  defp edge_between_js(edge, upper, lower) do
    """
    (() => {
      const line = document.querySelector('#{edge} path:last-of-type').getBoundingClientRect()
      const upper = document.getElementById('topology-map-node-#{upper.id}').getBoundingClientRect()
      const lower = document.getElementById('topology-map-node-#{lower.id}').getBoundingClientRect()
      return line.height > 0 &&
        Math.abs(line.top - upper.bottom) < 2 &&
        Math.abs(line.bottom - lower.top) < 2
    })()
    """
  end

  defp fits_width_js do
    "document.documentElement.scrollWidth <= document.documentElement.clientWidth"
  end

  defp open_heights_js do
    """
    Array.from(document.querySelectorAll('#links a[id$="-open"]'))
      .map((element) => element.getBoundingClientRect().height)
    """
  end
end
