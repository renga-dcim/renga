defmodule RengaWeb.Browser.PowerTest do
  use PhoenixTest.Playwright.Case, async: true

  import Renga.AccountsFixtures
  import Renga.CatalogFixtures
  import Renga.InventoryFixtures
  import Renga.PowerReadingFixtures

  alias Renga.Accounts
  alias Renga.DCIM
  alias Renga.Power
  alias Renga.Power.Cables
  alias Renga.Power.History
  alias Renga.Telemetry.Store

  @moduletag :playwright
  @phone [has_touch: true, is_mobile: true, viewport: %{width: 390, height: 844}]
  @tablet [has_touch: true, viewport: %{width: 820, height: 900}]
  @rack_pdu_name "rackpduwithanextremelylongunbrokenidentifierthatmustwrapinthepathpanelwithoutoverflow"
  @floor_pdu_name "floor-pdu-upstream"
  @long_port_name "psuwithanextremelylongunbrokenidentifierthatmustwrapinthepathpaneltitlewithoutoverflow"
  @long_inlet_name "inletwithanextremelylongunbrokenidentifierthatmustwrapinthepathstopwithoutoverflow"
  @long_sensor "redfish/Chassis/1/Power/PowerSupplies/0/PowerInputWattsWithAVeryLongVendorSuffix"
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

    {orphan_pdu, _expected} =
      assigned_server_fixture(scope, "orphan-pdu", [
        %{kind: "power_port", name: @long_inlet_name},
        %{
          kind: "power_outlet",
          name: "9",
          attributes: %{"inlet" => @long_inlet_name}
        }
      ])

    {long_port_server, _expected} =
      assigned_server_fixture(scope, "long-endpoint-server", [
        %{kind: "power_port", name: @long_port_name}
      ])

    %{ports: [port]} = Power.list_device_endpoints(scope, server.id)

    %{ports: [rack_inlet], outlets: [rack_outlet, _rack_outlet8]} =
      Power.list_device_endpoints(scope, rack_pdu.id)

    %{ports: [floor_inlet], outlets: [floor_outlet]} =
      Power.list_device_endpoints(scope, floor_pdu.id)

    %{outlets: [orphan_outlet]} = Power.list_device_endpoints(scope, orphan_pdu.id)

    %{ports: [long_port]} = Power.list_device_endpoints(scope, long_port_server.id)

    {:ok, _assertion} =
      Cables.connect(scope, %{power_port_id: floor_inlet.id, power_feed_id: feed.id})

    {:ok, _assertion} =
      Cables.connect(scope, %{
        power_port_id: rack_inlet.id,
        power_outlet_id: floor_outlet.id
      })

    {:ok, _assertion} =
      Cables.connect(scope, %{
        power_port_id: long_port.id,
        power_outlet_id: orphan_outlet.id
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
      rack_outlet: rack_outlet,
      long_port_server: long_port_server,
      long_port: long_port
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
    |> assert_has("#{connect}:focus")
    |> click(path)
    |> assert_has("#power-path-detail", text: "Outlet 8 via inlet Inlet")
    |> press("#path-panel [role=dialog]", "Escape")
    |> refute_has("#path-panel [role=dialog]")
    |> click_button("#unplug-port-#{context.port.id}", "Unplug")
    |> assert_has(path, text: "Not recorded")
  end

  @tag browser_context_opts: @phone
  test "the measured input trend fits a phone and switches period", context do
    %{scope: scope, server: server} = context

    bmc =
      power_stream_fixture(
        Renga.Repo.get!(Renga.Accounts.Organization, scope.organization_id),
        "bmc_power"
      )

    target_resource_fixture(bmc, "bmc-web-1", server)

    reading_fixture(bmc,
      target: "bmc-web-1",
      sensor: "PSU1/input",
      boundary: "supply_input",
      component: {"power_port", "PSU1"},
      value: 240
    )

    now = Renga.Time.utc_now_ms()
    series = History.device_series(server.id)

    # A day of load, with a two-hour gap where the BMC went quiet.
    samples =
      for minutes <- 0..1_438//2,
          minutes not in 600..720,
          do: %{
            series: series,
            at: DateTime.add(now, -minutes * 60, :second),
            value: 220 + 60 * :math.sin(minutes / 90)
          }

    :ok = Store.write(scope, samples)

    context.conn
    |> visit("/inventory/#{server.id}/power")
    |> assert_has("body .phx-connected")
    |> assert_has("#power-input-trend-summary",
      text: "Gaps are periods without a current reading"
    )
    |> evaluate(
      "document.documentElement.scrollWidth <= document.documentElement.clientWidth",
      &assert(&1 == true)
    )
    |> click("#power-input-trend-range-7d")
    |> assert_has("#power-input-trend-summary", text: "Over the last 7 days")
  end

  @tag browser_context_opts: @phone
  test "a feed's measured load trend fits its panel on a phone", context do
    %{scope: scope, feed: feed} = context
    now = Renga.Time.utc_now_ms()

    :ok =
      Store.write(
        scope,
        for(
          minutes <- 0..1_438//2,
          do: %{
            series: History.feed_series(feed),
            at: DateTime.add(now, -minutes * 60, :second),
            value: 1_800 + 400 * :math.cos(minutes / 120)
          }
        )
      )

    context.conn
    |> visit("/places/sites/#{context.site.id}/power")
    |> assert_has("body .phx-connected")
    |> click("#feed-#{feed.id}-measured")
    |> assert_has("#load-panel [role=dialog] #measured-trend-summary",
      text: "The dashed line is usable capacity."
    )
    |> evaluate(
      """
      (() => {
        const panel = document.getElementById('load-panel-container').getBoundingClientRect();
        const figure = document.getElementById('measured-trend');
        const box = figure.getBoundingClientRect();
        return box.left >= panel.left && box.right <= panel.right + 0.5 &&
          [figure, ...figure.querySelectorAll('*')].every(element =>
            element.scrollWidth <= element.clientWidth + 0.5);
      })()
      """,
      &assert(&1 == true)
    )
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

  @tag browser_context_opts: @phone
  test "power readings stay one line per row on a phone and reveal clipped values", context do
    first = readings!(context)

    context.conn
    |> visit("/inventory/#{context.server.id}/power")
    |> assert_has("body .phx-connected")
    |> assert_has("#power-readings tr", text: "Current")
    |> evaluate(readings_layout_js(), fn layout ->
      assert layout["fits"]
      assert layout["page_fits"]
      # Source and Taken give way; what is measured, its value, and status stay.
      assert layout["visible"] == ["Measures", "Value", "Status"]
      assert length(layout["rows"]) == 2
      assert Enum.all?(layout["rows"], &(&1 == hd(layout["rows"])))
    end)
    |> touch("#power-reading-#{first.id} td:first-child [data-clip]")
    |> evaluate(@tooltip, &assert(&1 =~ @long_sensor))
  end

  test "power readings keep compact one-line rows on a desktop", context do
    first = readings!(context)

    context.conn
    |> visit("/inventory/#{context.server.id}/power")
    |> assert_has("body .phx-connected")
    |> evaluate("document.documentElement.dataset.density = 'compact'")
    |> evaluate(readings_layout_js(), fn layout ->
      assert layout["fits"]
      assert "Source" in layout["visible"]
      assert Enum.all?(layout["rows"], &(&1 == 28))
    end)
    |> hover("#power-reading-#{first.id} td:first-child [data-clip]")
    |> evaluate(@tooltip, &assert(&1 =~ @long_sensor))
  end

  @tag browser_context_opts: @phone
  test "an owner sets the default power factor on a phone with tappable controls", context do
    organization = Renga.Repo.get!(Renga.Accounts.Organization, context.scope.organization_id)
    owner = user_fixture()
    organization_membership_fixture(owner, organization, %{role: "owner"})

    context.conn
    |> add_session_cookie(
      [
        value: %{
          user_token: Accounts.generate_user_session_token(owner),
          current_organization_id: organization.id
        }
      ],
      RengaWeb.Endpoint.session_options()
    )
    |> visit("/places/sites/#{context.site.id}/power")
    |> assert_has("body .phx-connected")
    |> assert_has("#default-power-factor", text: "Not set")
    |> evaluate(tap_sizes_js("#edit-default-power-factor"), &assert_tappable/1)
    |> click("#edit-default-power-factor")
    |> assert_has("#power-factor-panel [role=dialog]")
    |> evaluate(panel_fits_js("power-factor-panel"), &assert(&1 == true))
    |> evaluate(tap_sizes_js("#power-factor-form button"), &assert_tappable/1)
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

  @tag browser_context_opts: @phone
  test "long endpoint names wrap in an incomplete phone path panel", context do
    path = "#power-path-#{context.long_port.id}"

    context.conn
    |> visit("/inventory/#{context.long_port_server.id}/power")
    |> assert_has("body .phx-connected")
    |> click(path)
    |> assert_has("#path-panel-title", text: @long_port_name)
    |> assert_has("#power-path-terminal", text: @long_inlet_name)
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
      const panel = document.getElementById('#{id}-container');
      const box = panel.getBoundingClientRect();
      const contentFits = [...panel.querySelectorAll('*')].every(element =>
        element.scrollWidth <= element.clientWidth + 0.5
      );
      return box.left >= 0 && box.right <= document.documentElement.clientWidth + 0.5 &&
        box.width >= panel.scrollWidth && contentFits &&
        document.documentElement.scrollWidth <= document.documentElement.clientWidth;
    })()
    """
  end

  defp readings!(context) do
    organization = Renga.Repo.get!(Renga.Accounts.Organization, context.server.organization_id)
    bmc = power_stream_fixture(organization, "bmc_power")
    target_resource_fixture(bmc, "https://bmc-web-1", context.server)

    reading = fn attrs ->
      reading_fixture(
        bmc,
        [
          target: "https://bmc-web-1",
          boundary: "supply_input",
          component: {"power_port", "PSU1"},
          mapping_name: "redfish"
        ] ++ attrs
      )
    end

    reading.(sensor: @long_sensor, quantity: "real_power", value: 212.4)
    reading.(sensor: "psu1-state", quantity: "state", unit: nil, state: "ok")

    context.scope
    |> Renga.Power.Readings.for_resources([context.server.id], Renga.Time.utc_now_ms())
    |> Map.fetch!(context.server.id)
    |> Enum.map(& &1.reading)
    |> Enum.find(&(&1.sensor == @long_sensor))
  end

  defp readings_layout_js do
    """
    (() => {
      const body = document.getElementById('power-readings');
      const box = body.closest('div');
      return {
        fits: box.scrollWidth <= box.clientWidth + 0.5,
        page_fits: document.documentElement.scrollWidth <= document.documentElement.clientWidth,
        visible: [...box.querySelectorAll('thead th')]
          .filter(th => getComputedStyle(th).display !== 'none')
          .map(th => th.textContent.trim()),
        rows: [...body.querySelectorAll('tr[data-list-row]')]
          .map(row => row.getBoundingClientRect().height)
      };
    })()
    """
  end

  defp hover(conn, selector) do
    unwrap(conn, fn %{frame_id: frame_id} ->
      assert {:ok, _} = PlaywrightEx.Frame.hover(frame_id, selector: selector, timeout: 2000)
    end)
  end

  defp touch(conn, selector) do
    unwrap(conn, fn %{frame_id: frame_id} ->
      for type <- ~w(pointerdown pointerup) do
        assert {:ok, _} =
                 PlaywrightEx.Frame.dispatch_event(frame_id,
                   selector: selector,
                   type: type,
                   event_init: %{pointerType: "touch", bubbles: true},
                   timeout: 2000
                 )
      end
    end)
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
