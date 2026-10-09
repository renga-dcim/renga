defmodule RengaWeb.Browser.PhoneTasksTest do
  @moduledoc """
  The phone-complete tasks from RFD 8 ("Phone and tablet") that the
  area-specific phone tests do not already cover, at 390px with touch:
  reading every tab of an object page and changing lifecycle, searching
  from the command menu, and finding a device by name, serial number, or
  asset tag. The Inbox, rack, triage, and Hardware tab tasks have their own
  phone tests next to their areas.
  """
  use PhoenixTest.Playwright.Case, async: true

  import Renga.AccountsFixtures
  import Renga.InventoryFixtures

  alias Renga.Inventory

  @moduletag :playwright
  @moduletag browser_context_opts: [
               has_touch: true,
               is_mobile: true,
               viewport: %{width: 390, height: 844}
             ]

  setup %{conn: conn} do
    organization = organization_fixture()
    user = user_fixture()
    organization_membership_fixture(user, organization, %{role: "admin"})
    scope = Renga.Accounts.scope_for_user(user, organization.id)

    {:ok, server} =
      Inventory.create_resource(scope, %{
        kind: "server",
        name: "r12-u07-db-primary",
        lifecycle_state: "active"
      })

    {:ok, _} =
      Inventory.create_resource_identifier(scope, server.id, %{
        kind: "serial_number",
        value: "7X42KQ9"
      })

    {:ok, _} =
      Inventory.create_resource_identifier(scope, server.id, %{
        kind: "asset_tag",
        value: "AT-004512"
      })

    {:ok, _other} =
      Inventory.create_resource(scope, %{
        kind: "server",
        name: "r12-u09-web",
        lifecycle_state: "active"
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

    %{conn: conn, server: server}
  end

  test "reads every tab of an object page and changes lifecycle", %{conn: conn} = context do
    session =
      conn
      |> visit("/inventory/#{context.server.id}")
      |> assert_has("body .phx-connected")
      |> assert_has("#resource-detail h1", text: "r12-u07-db-primary")
      |> evaluate(fits_js(), &assert(&1 == true))
      |> evaluate(heights_js("#resource-detail-tabs a"), &assert_tappable/1)

    tabs = ~w(Overview Hardware Network Sources Activity)

    session =
      Enum.reduce(tabs, session, fn tab, session ->
        session
        |> click_link("#resource-detail-tabs a", tab)
        |> assert_has("#resource-detail-tabs a[aria-current=page]", text: tab)
        |> assert_has("body .phx-connected")
        |> evaluate(fits_js(), &assert(&1 == true))
      end)

    # Opened straight from a link, a later tab starts scrolled into view.
    session
    |> visit("/inventory/#{context.server.id}/activity")
    |> assert_has("body .phx-connected")
    |> evaluate(active_tab_in_view_js(), &assert(&1 == true))
    |> click_link("#resource-detail-tabs a", "Overview")
    |> assert_has("#resource-detail-tabs a[aria-current=page]", text: "Overview")
    |> evaluate(
      heights_js("#resource-lifecycle-form select, #resource-lifecycle-save"),
      &assert_tappable/1
    )
    |> select("#resource-lifecycle-form select", "Lifecycle", option: "Inactive — out of service")
    |> click_button("#resource-lifecycle-save", "Save")
    |> assert_has("#flash-info", text: "lifecycle updated")
    |> assert_has("#resource-status", text: "Inactive")
  end

  test "searches from the command menu and opens the device", %{conn: conn} = context do
    conn
    |> visit("/inbox")
    |> assert_has("body .phx-connected")
    |> evaluate(
      heights_js("#app-mobile-header button, #app-mobile-header summary"),
      &assert_tappable/1
    )
    |> click("#command-palette-trigger-mobile")
    |> assert_has("#command-palette[open]")
    |> evaluate(menu_fits_js(), &assert(&1 == true))
    |> evaluate(
      heights_js(
        "#command-palette [data-command-item]:not([hidden]) :is(a, button), #command-palette button[data-command-item]"
      ),
      &assert_tappable/1
    )
    |> type("#command-palette-input", "7X42KQ9")
    |> assert_has("#command-resource-search [data-search-label]",
      text: "Search resources for “7X42KQ9”"
    )
    |> assert_has("#command-resource-search a .hero-magnifying-glass")
    # Headings whose items the query filtered out are hidden with them.
    |> evaluate(visible_groups_js(), &assert(&1 == ["Search"]))
    |> evaluate(
      heights_js("#command-palette [data-command-item]:not([hidden]) a"),
      &assert_tappable/1
    )
    |> press("#command-palette-input", "Enter")
    |> assert_has("#resource-count", text: "1")
    |> click_link("#resources a", "r12-u07-db-primary")
    |> assert_has("#resource-detail h1", text: "r12-u07-db-primary")
    |> assert_path("/inventory/#{context.server.id}")
  end

  test "finds a device by name, serial number, or asset tag", %{conn: conn} do
    session =
      conn
      |> visit("/inventory")
      |> assert_has("body .phx-connected")
      |> evaluate(fits_js(), &assert(&1 == true))
      |> evaluate(heights_js("#resource-search-input"), &assert_tappable/1)

    for term <- ["db-primary", "7x42kq9", "AT-004512"], reduce: session do
      session ->
        session
        |> fill_in("#resource-search-input", "Search inventory", with: term)
        |> assert_has("#resources a", text: "r12-u07-db-primary")
        |> refute_has("#resources a", text: "r12-u09-web")
        |> evaluate(fits_js(), &assert(&1 == true))
        |> evaluate(heights_js("#resources a"), &assert_tappable/1)
    end
  end

  defp assert_tappable(heights) do
    assert heights != []
    assert Enum.all?(heights, &(round(&1) >= 44)), "tap targets under 44px: #{inspect(heights)}"
  end

  defp fits_js, do: "document.documentElement.scrollWidth <= document.documentElement.clientWidth"

  defp menu_fits_js do
    """
    (() => {
      const box = document.getElementById('command-palette').getBoundingClientRect();
      return box.left >= 0 && box.right <= document.documentElement.clientWidth + 0.5;
    })()
    """
  end

  # The tabs scroll sideways in one row; the current one must not be cut off.
  defp active_tab_in_view_js do
    """
    (() => {
      const strip = document.getElementById('resource-detail-tabs').getBoundingClientRect();
      const tab = document.querySelector('#resource-detail-tabs [aria-current=page]').getBoundingClientRect();
      return tab.left >= strip.left - 0.5 && tab.right <= strip.right + 0.5;
    })()
    """
  end

  defp visible_groups_js do
    """
    [...document.querySelectorAll('#command-palette [data-command-group]')]
      .filter(group => group.checkVisibility())
      .map(group => group.textContent.trim())
    """
  end

  defp heights_js(selector) do
    """
    [...document.querySelectorAll(#{Renga.JSON.encode!(selector)})]
      .filter(el => el.checkVisibility())
      .map(el => el.getBoundingClientRect().height)
    """
  end
end
