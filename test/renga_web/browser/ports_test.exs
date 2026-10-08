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

  setup %{conn: conn} do
    organization = organization_fixture()
    user = user_fixture()
    organization_membership_fixture(user, organization, %{role: "admin"})
    scope = Renga.Accounts.scope_for_user(user, organization.id)

    group = vlan_group_fixture(scope, "browser-ports")
    users = vlan_fixture(scope, group, 10, "users")
    vlan_fixture(scope, group, 20, "voice")

    names = for n <- 1..48, do: {"swp#{n}", %{status: if(rem(n, 3) == 0, do: "down", else: "up")}}
    {leaf, ports} = device_fixture(scope, "switch", "leaf-01", names)

    desire_vlans(scope, ports["swp40"], "access", users)
    report_vlans(scope, leaf, group, %{"swp40" => {"trunk", [{10, "untagged"}, {20, "tagged"}]}})

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

    %{conn: conn, leaf: leaf, swp40: ports["swp40"].id}
  end

  test "a front panel port focuses and expands its row", context do
    context.conn
    |> visit("/inventory/#{context.leaf.id}/ports")
    |> assert_has("body .phx-connected")
    |> assert_has("#panel-port-#{context.swp40}[data-drift='true']")
    |> click_button("#panel-port-#{context.swp40}", "40")
    |> assert_has("#port-#{context.swp40}-details")
    |> assert_has("#port-#{context.swp40}-open:focus")
    |> evaluate(in_view_js("#port-#{context.swp40}"), &assert(&1 == true))
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
    |> evaluate("document.documentElement.scrollWidth <= window.innerWidth", &assert(&1 == true))
    |> evaluate(open_heights_js(), fn heights ->
      assert length(heights) == 48
      assert Enum.all?(heights, &(round(&1) >= 44))
    end)
    |> click_link("#port-#{context.swp40}-drift", "VLAN drift")
    |> assert_has("#port-#{context.swp40}-membership [data-flag='unexpected']")
    # The expanded row widens the table; it scrolls, the page does not.
    |> evaluate("document.documentElement.scrollWidth <= window.innerWidth", &assert(&1 == true))
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
    Array.from(document.querySelectorAll('#ports a[id$="-open"]'))
      .map((element) => element.getBoundingClientRect().height)
    """
  end
end
