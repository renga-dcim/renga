defmodule RengaWeb.Browser.PortsTest do
  @moduledoc """
  A switch's Ports tab in a real browser: choosing a port on the front panel
  moves focus to its row and expands it, and at phone width the page stays
  within the screen with 44px port targets in the table.
  """
  use PhoenixTest.Playwright.Case, async: true

  import Renga.AccountsFixtures
  import Renga.InventoryFixtures
  import Renga.TopologyFixtures

  @moduletag :playwright

  @tooltip """
  new Promise(resolve => setTimeout(() => {
    const tooltip = document.getElementById("clip-tooltip")
    resolve(tooltip?.matches(":popover-open") ? tooltip.textContent : null)
  }, 600))
  """

  setup %{conn: conn} do
    organization = organization_fixture()
    user = user_fixture()
    organization_membership_fixture(user, organization, %{role: "admin"})
    scope = Renga.Accounts.scope_for_user(user, organization.id)

    group = vlan_group_fixture(scope, "browser-ports")
    users = vlan_fixture(scope, group, 10, "users")

    tagged =
      for vid <- [20, 30, 50, 80, 130, 210, 340, 550] do
        vlan_fixture(scope, group, vid, "tagged-#{vid}")
      end

    names = for n <- 1..48, do: {"swp#{n}", %{status: if(rem(n, 3) == 0, do: "down", else: "up")}}
    {leaf, ports} = device_fixture(scope, "switch", "leaf-01", names)

    remote_name = "distribution-switch-building-a-floor-twenty-two"
    remote_port_name = "forty-gigabit-ethernet-0/0/48"
    {remote, remote_ports} = device_fixture(scope, "switch", remote_name, [remote_port_name])
    cable_fixture(scope, ports["swp40"], remote_ports[remote_port_name], %{label: "uplink-a"})
    report_neighbors(scope, leaf, %{"swp40" => {remote.name, remote_port_name}})

    desire_vlans(scope, ports["swp40"], "trunk", users, Enum.drop(tagged, -1))

    report_vlans(scope, leaf, group, %{
      "swp40" => {"trunk", [{10, "untagged"} | Enum.map(tagged, &{&1.vid, "tagged"})]}
    })

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
      leaf: leaf,
      remote_name: remote_name,
      remote_port_name: remote_port_name,
      swp40: ports["swp40"].id
    }
  end

  test "a front panel port focuses and expands its row", context do
    context.conn
    |> visit("/inventory/#{context.leaf.id}/ports")
    |> assert_has("body .phx-connected")
    |> assert_has("#panel-port-#{context.swp40}[data-drift='true']")
    |> click_button("#panel-port-#{context.swp40}", "40")
    |> assert_has("#port-#{context.swp40}-details")
    |> assert_has("#port-#{context.swp40}-link:focus")
    |> evaluate(in_view_js("#port-#{context.swp40}"), &assert(&1 == true))
  end

  test "long neighbors and tagged VLAN lists reveal their full values", context do
    neighbor = "#port-#{context.swp40} td:nth-child(3) a[data-clip]"
    tagged = "#port-#{context.swp40} td:nth-child(7) [data-clip]"

    context.conn
    |> visit("/inventory/#{context.leaf.id}/ports")
    |> assert_has("body .phx-connected")
    |> evaluate(
      "document.querySelector(#{Jason.encode!(neighbor)}).scrollWidth > document.querySelector(#{Jason.encode!(neighbor)}).clientWidth",
      &assert(&1 == true)
    )
    |> hover(neighbor)
    |> evaluate(
      @tooltip,
      &assert(&1 =~ "#{context.remote_port_name} #{context.remote_name}")
    )
    |> hover(tagged)
    |> evaluate(@tooltip, &assert(&1 =~ "20, 30, 50, 80, 130, 210, 340, 550"))
  end

  @tag browser_context_opts: [
         has_touch: true,
         is_mobile: true,
         viewport: %{width: 390, height: 844}
       ]
  test "fits a phone screen with tappable ports", context do
    context.conn
    |> visit("/inventory/#{context.leaf.id}/ports")
    |> assert_has("body .phx-connected")
    |> evaluate(
      "document.documentElement.scrollWidth <= document.documentElement.clientWidth",
      &assert(&1 == true)
    )
    |> evaluate(open_heights_js(), fn heights ->
      assert length(heights) == 48
      assert Enum.all?(heights, &(round(&1) >= 44))
    end)
    |> evaluate(
      "(() => { const wrapper = document.querySelector('#ports').closest('table').parentElement; return wrapper.scrollWidth <= wrapper.clientWidth })()",
      &assert(&1 == true)
    )
    |> tab_until("#port-#{context.swp40} td:nth-child(3) a[data-clip]")
    |> evaluate(@tooltip, &assert(&1 =~ context.remote_name))
    |> click("#port-#{context.swp40}-drift")
    |> assert_has("#port-#{context.swp40}-membership [data-flag='unexpected']")
    |> evaluate(
      "(() => { const wrapper = document.querySelector('#ports').closest('table').parentElement; return wrapper.scrollWidth <= wrapper.clientWidth && document.documentElement.scrollWidth <= document.documentElement.clientWidth })()",
      &assert(&1 == true)
    )
  end

  defp hover(conn, selector) do
    unwrap(conn, fn %{frame_id: frame_id} ->
      assert {:ok, _} = PlaywrightEx.Frame.hover(frame_id, selector: selector, timeout: 2000)
    end)
  end

  defp tab_until(session, selector) do
    Enum.reduce_while(1..120, session, fn _, session ->
      session = press(session, "body", "Tab")

      session
      |> evaluate("document.activeElement.matches(#{Jason.encode!(selector)})", fn reached? ->
        send(self(), {:focus_reached, reached?})
      end)

      reached? = receive do: ({:focus_reached, reached?} -> reached?)
      if reached?, do: {:halt, session}, else: {:cont, session}
    end)
  end

  defp in_view_js(selector) do
    """
    (() => {
      const box = document.querySelector('#{selector}').getBoundingClientRect()
      return box.top >= 0 && box.bottom <= window.innerHeight
    })()
    """
  end

  defp open_heights_js do
    """
    Array.from(document.querySelectorAll('#ports a[id$="-link"]'))
      .map((element) => element.getBoundingClientRect().height)
    """
  end
end
