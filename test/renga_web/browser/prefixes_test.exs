defmodule RengaWeb.Browser.PrefixesTest do
  @moduledoc """
  The prefix views in a real browser: a container's space map opens the
  child a cell stands for, and at phone width long IPv6 prefixes keep their
  usage beside or below them rather than drawn over them.
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

    site = prefix_fixture(scope, "2001:db8:a::/48")
    hall = prefix_fixture(scope, "2001:db8:a:100::/56")
    prefix_fixture(scope, "2001:db8:a:100::/64")
    prefix_fixture(scope, "2001:db8:a:300::/56")
    prefix_fixture(scope, "10.0.0.0/16")
    prefix_fixture(scope, "10.0.10.0/24")

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

    %{conn: conn, site: site, hall: hall}
  end

  test "a space map cell opens the child it stands for", context do
    context.conn
    |> visit("/network/prefixes/#{context.site.id}")
    |> assert_has("body .phx-connected")
    |> assert_has("#prefix-space-summary", text: "2 of 256 /56s allocated")
    |> PhoenixTest.Playwright.click("#prefix-space-map a[title='2001:db8:a:100::/56']")
    |> assert_has("#prefix-detail h1", text: "2001:db8:a:100::/56")
  end

  @tag browser_context_opts: [
         has_touch: true,
         is_mobile: true,
         viewport: %{width: 390, height: 844}
       ]
  test "rows never draw usage over the prefix on a phone", context do
    context.conn
    |> visit("/network/prefixes")
    |> assert_has("body .phx-connected")
    |> evaluate("document.documentElement.scrollWidth <= window.innerWidth", &assert(&1 == true))
    |> evaluate(
      """
      Array.from(document.querySelectorAll('[id^="prefix-row-"][data-highlighted]')).map((row) => {
        const a = row.querySelector('a').getBoundingClientRect()
        const u = row.querySelector('[data-usage]').getBoundingClientRect()
        return u.left >= a.right || u.top >= a.bottom
      })
      """,
      fn checks ->
        assert length(checks) == 6
        assert Enum.all?(checks)
      end
    )
  end
end
