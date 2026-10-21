defmodule RengaWeb.SitePowerLiveTest do
  use RengaWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Renga.AccountsFixtures
  import Renga.InventoryFixtures

  alias Renga.Accounts
  alias Renga.DCIM
  alias Renga.Power

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
end
