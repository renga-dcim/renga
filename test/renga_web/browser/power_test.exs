defmodule RengaWeb.Browser.PowerTest do
  use PhoenixTest.Playwright.Case, async: true

  import Renga.AccountsFixtures
  import Renga.CatalogFixtures
  import Renga.InventoryFixtures

  alias Renga.Accounts
  alias Renga.DCIM
  alias Renga.Power
  alias Renga.Power.Cables

  @moduletag :playwright
  @phone [has_touch: true, is_mobile: true, viewport: %{width: 390, height: 844}]
  @tablet [has_touch: true, viewport: %{width: 820, height: 900}]
  @rack_pdu_name "rack-pdu-with-an-extremely-long-unbroken-identifier-that-must-wrap-in-the-path-panel"
  @floor_pdu_name "floor-pdu-upstream"

  setup %{conn: conn} do
    organization = organization_fixture()
    user = user_fixture()
    organization_membership_fixture(user, organization, %{role: "admin"})
    scope = Accounts.scope_for_user(user, organization.id)
    {:ok, site} = DCIM.create_site(scope, %{name: "DC1"}, %{slug: "dc1"})

    {:ok, panel} =
      Power.create_panel(scope, %{
        site_id: site.id,
        name: "Distribution Panel Alpha With A Long Identifying Label"
      })

    {:ok, feed} =
      Power.create_feed(scope, panel.id, %{
        name: "A1",
        side: "a",
        supply: "ac",
        phase: "single",
        voltage: "230",
        amperage: "16"
      })

    {server, _expected} =
      assigned_server_fixture(scope, "web-1", [
        %{kind: "power_port", name: "PSU1", attributes: %{"allocated_draw_w" => 350}}
      ])

    {rack_pdu, _expected} =
      assigned_server_fixture(scope, @rack_pdu_name, [
        %{kind: "power_port", name: "Inlet"},
        %{kind: "power_outlet", name: "7", attributes: %{"inlet" => "Inlet"}},
        %{kind: "power_outlet", name: "8", attributes: %{"inlet" => "Inlet"}}
      ])

    {floor_pdu, _expected} =
      assigned_server_fixture(scope, @floor_pdu_name, [
        %{kind: "power_port", name: "Inlet"},
        %{kind: "power_outlet", name: "1", attributes: %{"inlet" => "Inlet"}}
      ])

    %{ports: [port]} = Power.list_device_endpoints(scope, server.id)

    %{ports: [rack_inlet], outlets: [rack_outlet, _rack_outlet8]} =
      Power.list_device_endpoints(scope, rack_pdu.id)

    %{ports: [floor_inlet], outlets: [floor_outlet]} =
      Power.list_device_endpoints(scope, floor_pdu.id)

    {:ok, _assertion} =
      Cables.connect(scope, %{power_port_id: floor_inlet.id, power_feed_id: feed.id})

    {:ok, _assertion} =
      Cables.connect(scope, %{
        power_port_id: rack_inlet.id,
        power_outlet_id: floor_outlet.id
      })

    conn =
      add_session_cookie(
        conn,
        [
          value: %{
            user_token: Accounts.generate_user_session_token(user),
            current_organization_id: organization.id
          }
        ],
        RengaWeb.Endpoint.session_options()
      )

    %{
      conn: conn,
      scope: scope,
      site: site,
      feed: feed,
      server: server,
      port: port,
      rack_outlet: rack_outlet
    }
  end

  test "a feed editor opens from the keyboard and restores focus when closed", context do
    edit = "#feed-#{context.feed.id}-edit"

    context.conn
    |> visit("/places/sites/#{context.site.id}/power")
    |> assert_has("body .phx-connected")
    |> evaluate("document.querySelector(#{Jason.encode!(edit)}).focus()")
    |> assert_has("#{edit}:focus")
    |> press(":focus", "Enter")
    |> assert_has("#feed-panel [role=dialog]", text: "Edit A1")
    |> evaluate(
      "document.querySelector('#feed-panel [role=dialog]').contains(document.activeElement)",
      &assert(&1 == true)
    )
    |> press("#feed-panel [role=dialog]", "Escape")
    |> refute_has("#feed-panel [role=dialog]")
    |> assert_has("#{edit}:focus")
  end

  test "an allocation editor opens from the keyboard and restores focus when closed", context do
    edit = "#power-port-#{context.port.id}-edit"

    context.conn
    |> visit("/inventory/#{context.server.id}/power")
    |> assert_has("body .phx-connected")
    |> evaluate("document.querySelector(#{Jason.encode!(edit)}).focus()")
    |> assert_has("#{edit}:focus")
    |> press(":focus", "Enter")
    |> assert_has("#allocation-panel [role=dialog]", text: "Allocate PSU1")
    |> evaluate(
      "document.querySelector('#allocation-panel [role=dialog]').contains(document.activeElement)",
      &assert(&1 == true)
    )
    |> press("#allocation-panel [role=dialog]", "Escape")
    |> refute_has("#allocation-panel [role=dialog]")
    |> assert_has("#{edit}:focus")
  end

  test "a connection editor works from the keyboard and restores focus", context do
    connect = "#connect-port-#{context.port.id}"
    path = "#power-path-#{context.port.id}"

    context.conn
    |> visit("/inventory/#{context.server.id}/power")
    |> assert_has("body .phx-connected")
    |> assert_has(path, text: "Not recorded")
    |> evaluate("document.querySelector(#{Jason.encode!(path)}).focus()")
    |> press(":focus", "Enter")
    |> assert_has("#path-panel [role=dialog]", text: "Power path for PSU1")
    |> assert_has("#power-path-terminal", text: "No connection is recorded")
    |> press("#path-panel [role=dialog]", "Escape")
    |> refute_has("#path-panel [role=dialog]")
    |> assert_has("#{path}:focus")
    |> evaluate("document.querySelector(#{Jason.encode!(connect)}).focus()")
    |> assert_has("#{connect}:focus")
    |> press(":focus", "Enter")
    |> assert_has("#connect-panel [role=dialog]", text: "Connect PSU1")
    |> evaluate(
      "document.querySelector('#connect-panel [role=dialog]').contains(document.activeElement)",
      &assert(&1 == true)
    )
    |> select("Plugged into", option: "Outlet 7", exact: false)
    |> click_button("#save-connection", "Connect")
    |> assert_has("#flash-info", text: "PSU1 connected")
    |> assert_has(
      path,
      text: "Distribution Panel Alpha With A Long Identifying Label A1 · 2 PDU hops"
    )
    |> assert_has(connect, text: "Move")
    |> evaluate("document.querySelector(#{Jason.encode!(path)}).focus()")
    |> assert_has("#{path}:focus")
    |> press(":focus", "Enter")
    |> assert_has("#path-panel [role=dialog]", text: "Power path for PSU1")
    |> assert_has("#power-path-detail", text: @rack_pdu_name)
    |> assert_has("#power-path-detail", text: "Outlet 7 via inlet Inlet")
    |> assert_has("#power-path-detail", text: @floor_pdu_name)
    |> assert_has("#power-path-detail", text: "Outlet 1 via inlet Inlet")
    |> assert_has(
      "#power-path-terminal",
      text: "Distribution Panel Alpha With A Long Identifying Label A1 side A"
    )
    |> evaluate(
      "document.querySelector('#path-panel [role=dialog]').contains(document.activeElement)",
      &assert(&1 == true)
    )
    |> press("#path-panel [role=dialog]", "Escape")
    |> refute_has("#path-panel [role=dialog]")
    |> assert_has("#{path}:focus")
    |> evaluate("document.querySelector(#{Jason.encode!(connect)}).focus()")
    |> press(":focus", "Enter")
    |> assert_has("#connect-panel [role=dialog]", text: "Move PSU1")
    |> select("Plugged into", option: "Outlet 8", exact: false)
    |> click_button("#save-connection", "Move")
    |> refute_has("#connect-panel [role=dialog]")
    |> assert_has("#flash-info", text: "PSU1 moved")
    |> assert_has("#power-port-#{context.port.id} .font-mono", text: "8", exact: true)
    |> assert_has("#{connect}:focus")
    |> click_button("#unplug-port-#{context.port.id}", "Unplug")
    |> assert_has("#power-port-#{context.port.id}", text: "Not recorded")
  end

  @tag browser_context_opts: @phone
  test "the Power tab and connection panel fit a phone with tappable controls", context do
    path = "#power-path-#{context.port.id}"

    context.conn
    |> visit("/inventory/#{context.server.id}/power")
    |> assert_has("body .phx-connected")
    |> evaluate(
      "document.documentElement.scrollWidth <= document.documentElement.clientWidth",
      &assert(&1 == true)
    )
    |> evaluate(local_table_fits_js(), &assert(&1 == true))
    |> evaluate(tap_sizes_js("#power-ports button"), &assert_tappable/1)
    |> click("#connect-port-#{context.port.id}")
    |> assert_has("#connect-panel [role=dialog]")
    |> evaluate(panel_fits_js("connect-panel"), &assert(&1 == true))
    |> evaluate(
      tap_sizes_js("#connect-form select, #connect-form button"),
      &assert_tappable/1
    )
    |> select("Plugged into", option: "Outlet 7", exact: false)
    |> click_button("#save-connection", "Connect")
    |> assert_has(path, text: "Distribution Panel Alpha With A Long Identifying Label")
    |> evaluate(
      "document.documentElement.scrollWidth <= document.documentElement.clientWidth",
      &assert(&1 == true)
    )
    |> evaluate(row_heights_js(), &assert_single_line_rows/1)
    |> click(path)
    |> assert_has("#path-panel [role=dialog]", text: "Power path for PSU1")
    |> assert_has("#power-path-detail", text: @rack_pdu_name)
    |> assert_has("#power-path-detail", text: @floor_pdu_name)
    |> evaluate(panel_fits_js("path-panel"), &assert(&1 == true))
    |> evaluate(tap_sizes_js("#path-panel a, #path-panel button"), &assert_tappable/1)
  end

  @tag browser_context_opts: @tablet
  test "connected actions and path controls stay tappable above the phone breakpoint", context do
    {:ok, _cable} =
      Cables.connect(context.scope, %{
        power_port_id: context.port.id,
        power_outlet_id: context.rack_outlet.id
      })

    path = "#power-path-#{context.port.id}"

    context.conn
    |> visit("/inventory/#{context.server.id}/power")
    |> assert_has("body .phx-connected")
    |> assert_has("#connect-port-#{context.port.id}", text: "Move")
    |> assert_has("#unplug-port-#{context.port.id}", text: "Unplug")
    |> evaluate(local_table_fits_js(), &assert(&1 == true))
    |> evaluate(tap_sizes_js("#power-ports button"), &assert_tappable/1)
    |> click(path)
    |> assert_has("#power-path-detail", text: @rack_pdu_name)
    |> evaluate(panel_fits_js("path-panel"), &assert(&1 == true))
    |> evaluate(tap_sizes_js("#path-panel a, #path-panel button"), &assert_tappable/1)
  end

  defp assert_tappable(sizes) do
    assert sizes != []

    assert Enum.all?(sizes, &(round(&1["width"]) >= 44 and round(&1["height"]) >= 44)),
           "tap targets under 44×44px: #{inspect(sizes)}"
  end

  defp assert_single_line_rows(heights) do
    assert heights != []

    assert Enum.all?(heights, &(&1 >= 44 and &1 <= 45.5)),
           "expected compact one-line rows, got heights: #{inspect(heights)}"
  end

  defp panel_fits_js(id) do
    """
    (() => {
      const box = document.getElementById('#{id}-container').getBoundingClientRect();
      return box.left >= 0 && box.right <= document.documentElement.clientWidth + 0.5 &&
        box.width >= document.getElementById('#{id}-container').scrollWidth &&
        document.documentElement.scrollWidth <= document.documentElement.clientWidth;
    })()
    """
  end

  defp row_heights_js do
    """
    [...document.querySelectorAll('#power-ports > tr[data-list-row]')]
      .map(row => row.getBoundingClientRect().height)
    """
  end

  defp local_table_fits_js do
    """
    (() => {
      const box = document.getElementById('power-ports').closest('div');
      return box.scrollWidth <= box.clientWidth + 0.5;
    })()
    """
  end

  defp tap_sizes_js(selector) do
    """
    [...document.querySelectorAll(#{Renga.JSON.encode!(selector)})]
      .filter(element => element.offsetParent !== null)
      .map(element => {
        const box = element.getBoundingClientRect();
        return {width: box.width, height: box.height};
      })
    """
  end
end
