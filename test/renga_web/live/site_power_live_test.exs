defmodule RengaWeb.SitePowerLiveTest do
  use RengaWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Renga.AccountsFixtures
  import Renga.CatalogFixtures
  import Renga.InventoryFixtures

  alias Renga.Accounts
  alias Renga.DCIM
  alias Renga.Power
  alias Renga.Power.Cables

  setup %{conn: conn} do
    organization = organization_fixture()
    {conn, scope} = sign_in(conn, organization, "admin")
    {:ok, site} = DCIM.create_site(scope, %{name: "DC1"}, %{slug: "dc1"})
    %{conn: conn, scope: scope, site: site, organization: organization}
  end

  defp sign_in(conn, organization, role) do
    user = user_fixture()
    organization_membership_fixture(user, organization, %{role: role})

    conn =
      conn
      |> log_in_user(user)
      |> put_session(:current_organization_id, organization.id)

    {conn, Accounts.scope_for_user(user, organization.id)}
  end

  test "the site page links to its power tab", %{conn: conn, site: site} do
    {:ok, view, _html} = live(conn, ~p"/places/sites/#{site.id}")
    assert has_element?(view, "#site-detail a[href='/places/sites/#{site.id}/power']", "Power")
  end

  test "adds a panel and feeds and shows usable capacity by unit",
       %{conn: conn, site: site, scope: scope} do
    {:ok, rack} = DCIM.create_rack(scope, %{name: "R1"}, %{site_id: site.id})
    {:ok, view, _html} = live(conn, ~p"/places/sites/#{site.id}/power")

    assert has_element?(view, "#power-empty")

    view
    |> form("#new-panel-form", panel: %{name: "PDP-1"})
    |> render_submit()

    [panel] = Power.list_panels(scope, site.id)
    assert has_element?(view, "#panel-#{panel.id}", "PDP-1")

    view |> element("#new-feed-#{panel.id}") |> render_click()

    view
    |> form("#feed-form",
      feed: %{
        name: "A1",
        supply: "ac",
        phase: "three",
        voltage: "400",
        amperage: "32",
        max_utilization: "80",
        side: "a",
        rack_id: rack.id
      }
    )
    |> render_submit()

    [feed] = Power.list_rack_feeds(scope, rack.id)
    assert has_element?(view, "#feed-#{feed.id}-usable", "17,736 VA")
    assert has_element?(view, "#site-usable-va", "17,736 VA")

    view |> element("#new-feed-#{panel.id}") |> render_click()
    view |> form("#feed-form", feed: %{supply: "dc"}) |> render_change()
    refute has_element?(view, "#feed-form select[name='feed[phase]']")

    view
    |> form("#feed-form",
      feed: %{name: "DC1", voltage: "48", amperage: "100", max_utilization: "100"}
    )
    |> render_submit()

    assert has_element?(view, "#site-usable-w", "4,800 W")
    assert has_element?(view, "#site-usable-va", "17,736 VA")
  end

  test "edits a feed from its row", %{conn: conn, site: site, scope: scope} do
    {:ok, panel} = Power.create_panel(scope, %{site_id: site.id, name: "PDP-1"})

    {:ok, feed} =
      Power.create_feed(scope, panel.id, %{
        name: "A1",
        supply: "ac",
        voltage: "230",
        amperage: "16"
      })

    {:ok, view, _html} = live(conn, ~p"/places/sites/#{site.id}/power")
    assert has_element?(view, "#feed-#{feed.id}-usable", "2,944 VA")

    render_click(view, "edit_feed", %{id: feed.id})
    view |> form("#feed-form", feed: %{amperage: "32"}) |> render_submit()

    assert has_element?(view, "#feed-#{feed.id}-usable", "5,888 VA")
  end

  test "shows an invalid rating as an error", %{conn: conn, site: site, scope: scope} do
    {:ok, panel} = Power.create_panel(scope, %{site_id: site.id, name: "PDP-1"})
    {:ok, view, _html} = live(conn, ~p"/places/sites/#{site.id}/power")

    render_click(view, "new_feed", %{panel_id: panel.id})

    html =
      view
      |> form("#feed-form", feed: %{name: "A1", voltage: "0", amperage: "16"})
      |> render_submit()

    assert html =~ "Voltage must be greater than 0"
  end

  test "members read the power page without editing it",
       %{conn: conn, site: site, scope: scope, organization: organization} do
    {:ok, panel} = Power.create_panel(scope, %{site_id: site.id, name: "PDP-1"})
    {member_conn, _scope} = sign_in(build_conn(), organization, "member")
    _ = conn

    {:ok, view, _html} = live(member_conn, ~p"/places/sites/#{site.id}/power")
    assert has_element?(view, "#panel-#{panel.id}", "PDP-1")
    refute has_element?(view, "#new-panel")
    refute has_element?(view, "#new-feed-#{panel.id}")
    refute has_element?(view, "#feed-panel")
  end

  test "an owner sets and clears the default power factor", %{
    conn: conn,
    organization: organization,
    site: site,
    scope: scope
  } do
    {:ok, admin_view, _html} = live(conn, ~p"/places/sites/#{site.id}/power")
    assert has_element?(admin_view, "#default-power-factor", "Not set")
    refute has_element?(admin_view, "#edit-default-power-factor")
    refute has_element?(admin_view, "#power-factor-form")

    {owner_conn, _owner} = sign_in(conn, organization, "owner")
    {:ok, view, _html} = live(owner_conn, ~p"/places/sites/#{site.id}/power")

    assert view
           |> form("#power-factor-form", organization: %{default_power_factor: "0"})
           |> render_submit() =~ "must be greater than 0"

    view
    |> form("#power-factor-form", organization: %{default_power_factor: "0.9"})
    |> render_submit()

    assert has_element?(view, "#default-power-factor", "0.900")
    assert Decimal.eq?(Power.default_power_factor(scope), "0.9")

    # A value that is not text is rejected, never read as clearing the default.
    render_submit(view, "save_power_factor", %{
      "organization" => %{"default_power_factor" => %{"value" => "0.5"}}
    })

    assert Decimal.eq?(Power.default_power_factor(scope), "0.9")
    assert render(view) =~ "0.900"

    view
    |> form("#power-factor-form", organization: %{default_power_factor: ""})
    |> render_submit()

    assert has_element?(view, "#default-power-factor", "Not set")
  end

  defp feed!(scope, panel, name, attrs \\ %{}) do
    attrs = Map.merge(%{name: name, phase: "single", voltage: "230", amperage: "16"}, attrs)
    {:ok, feed} = Power.create_feed(scope, panel.id, attrs)
    feed
  end

  defp plug!(scope, name, attributes, target) do
    {server, _expected} =
      assigned_server_fixture(scope, name, [
        %{kind: "power_port", name: "PSU1", attributes: attributes}
      ])

    [port] = Power.list_device_endpoints(scope, server.id).ports

    target =
      case target do
        %Power.Feed{} -> %{power_feed_id: target.id}
        %Power.Outlet{} -> %{power_outlet_id: target.id}
      end

    {:ok, _cable} = Cables.connect(scope, Map.put(target, :power_port_id, port.id))
    port
  end

  test "shows each feed's allocated load and why one is unknown",
       %{conn: conn, site: site, scope: scope} do
    {:ok, panel} = Power.create_panel(scope, %{site_id: site.id, name: "PDP-1"})
    a1 = feed!(scope, panel, "A1")
    b1 = feed!(scope, panel, "B1")
    port = plug!(scope, "web-1", %{"allocated_draw_w" => 400, "power_factor" => "0.8"}, a1)
    plug!(scope, "web-2", %{"allocated_draw_w" => 300}, b1)

    {:ok, view, _html} = live(conn, ~p"/places/sites/#{site.id}/power")

    # 400 W at 0.8 is 500 VA of 2,944 VA usable.
    assert has_element?(view, "#feed-#{a1.id}-load[data-status=ok]", "500 VA")
    assert has_element?(view, "#feed-#{a1.id}-load", "17%")
    assert has_element?(view, "#feed-#{b1.id}-load[data-status=unknown]", "Unknown")
    assert has_element?(view, "#feed-#{b1.id}-load", "1 without power factor")

    view |> element("#feed-#{a1.id}-load") |> render_click()
    assert has_element?(view, "#load-panel-title", "A1 load")
    assert has_element?(view, "#load-headroom", "2,444 VA")
    assert has_element?(view, "#load-draw-#{port.id}", "web-1 · PSU1")
    assert has_element?(view, "#load-draw-#{port.id}", "400 W · 500 VA")
    assert has_element?(view, "#load-draw-#{port.id}", "Power factor 0.800, from hardware type")
    refute has_element?(view, "#load-default-power-factor")

    view |> element("#feed-#{b1.id}-load") |> render_click()
    assert has_element?(view, "#load-status", "Unknown")
    assert has_element?(view, "#load-incomplete", "1 load has no power factor")
  end

  test "labels load that rests on the organization's default power factor",
       %{conn: conn, site: site, scope: scope, organization: organization} do
    {:ok, panel} = Power.create_panel(scope, %{site_id: site.id, name: "PDP-1"})
    feed = feed!(scope, panel, "A1")
    plug!(scope, "web-1", %{"allocated_draw_w" => 450}, feed)
    {_owner_conn, owner} = sign_in(build_conn(), organization, "owner")
    {:ok, _organization} = Power.set_default_power_factor(owner, "0.9")

    {:ok, view, _html} = live(conn, ~p"/places/sites/#{site.id}/power")
    assert has_element?(view, "#feed-#{feed.id}-load", "500 VA")
    assert has_element?(view, "#feed-#{feed.id}-load", "Default power factor")

    view |> element("#feed-#{feed.id}-load") |> render_click()
    assert has_element?(view, "#load-default-power-factor", "default power factor of 0.900")
  end

  test "shows a three-phase leg over its limit while the feed has headroom",
       %{conn: conn, site: site, scope: scope} do
    {:ok, panel} = Power.create_panel(scope, %{site_id: site.id, name: "PDP-1"})
    feed = feed!(scope, panel, "A1", %{phase: "three", voltage: "400", amperage: "32"})

    {pdu, _expected} =
      assigned_server_fixture(scope, "rack-pdu", [
        %{kind: "power_port", name: "Inlet"},
        %{kind: "power_outlet", name: "1", attributes: %{"inlet" => "Inlet", "feed_leg" => "a"}},
        %{kind: "power_outlet", name: "2", attributes: %{"inlet" => "Inlet", "feed_leg" => "b"}}
      ])

    %{ports: [inlet], outlets: [a, b]} = Power.list_device_endpoints(scope, pdu.id)
    {:ok, _cable} = Cables.connect(scope, %{power_port_id: inlet.id, power_feed_id: feed.id})
    plug!(scope, "db-1", %{"allocated_draw_w" => 6000, "power_factor" => 1}, a)
    plug!(scope, "web-1", %{"allocated_draw_w" => 230, "power_factor" => 1}, b)

    {:ok, view, _html} = live(conn, ~p"/places/sites/#{site.id}/power")
    assert has_element?(view, "#feed-#{feed.id}-load[data-status=over]", "6,230 VA")
    assert has_element?(view, "#feed-#{feed.id}-load", "A leg is over its limit")

    view |> element("#feed-#{feed.id}-load") |> render_click()
    assert has_element?(view, "#load-status", "A leg is over its limit")
    assert has_element?(view, "#load-leg-a .text-crit", "26.0 A of 25.6 A")
    assert has_element?(view, "#load-leg-b", "1.0 A of 25.6 A")
    assert has_element?(view, "#load-leg-c", "0.0 A of 25.6 A")
  end
end
