defmodule RengaWeb.Browser.PrefixesTest do
  @moduledoc """
  The prefix views in a real browser: a container's space map opens the
  child a cell stands for, a prefix is created from the side panel, and at
  phone width long IPv6 prefixes keep their usage beside or below them,
  with the edit controls hidden because prefixes are not edited on a phone.
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

    %{conn: conn, site: site, hall: hall, scope: scope}
  end

  test "an IPv6 host prefix renders a valid address", context do
    prefix = prefix_fixture(context.scope, "2001:db8::1/128")
    {_host, ports} = device_fixture(context.scope, "server", "host-prefix", ~w(eth0))
    address = address_fixture(context.scope, ports["eth0"], "2001:db8::1/64")

    context.conn
    |> visit("/network/prefixes/#{prefix.id}")
    |> assert_has("body .phx-connected")
    |> assert_has("#address-#{address.id}")
    |> evaluate(
      "document.querySelector('#address-#{address.id} .font-mono').textContent.trim()",
      fn text ->
        assert {:ok, parsed} = :inet.parse_address(String.to_charlist(text))
        assert parsed == address.address.address
      end
    )
  end

  test "a space map cell opens the child it stands for", context do
    context.conn
    |> visit("/network/prefixes/#{context.site.id}")
    |> assert_has("body .phx-connected")
    |> assert_has("#prefix-space-summary", text: "2 of 256 /56s allocated")
    |> PhoenixTest.Playwright.click("#prefix-space-map a[title='2001:db8:a:100::/56']")
    |> assert_has("#prefix-detail h1", text: "2001:db8:a:100::/56")
  end

  test "an admin creates a prefix from the side panel", context do
    context.conn
    |> visit("/network/prefixes?family=ipv4")
    |> assert_has("body .phx-connected")
    |> PhoenixTest.Playwright.click("#new-prefix")
    |> assert_has("#prefix-panel [role=dialog]", text: "New prefix")
    |> fill_in("#prefix-form input[name='prefix[prefix]']", "CIDR", with: "10.0.20.0/24")
    |> fill_in("#prefix-form input[name='prefix[description]']", "Description (optional)",
      with: "Voice"
    )
    |> PhoenixTest.Playwright.click("#create-prefix")
    |> assert_has("#flash-info", text: "Prefix 10.0.20.0/24 created")
    |> assert_has("#prefix-tree-ipv4", text: "10.0.20.0/24")
    |> refute_has("#prefix-panel [role=dialog]")
  end

  @tag browser_context_opts: [
         has_touch: true,
         is_mobile: true,
         viewport: %{width: 390, height: 844}
       ]
  test "prefixes are readable but not editable on a phone", context do
    context.conn
    |> visit("/network/prefixes")
    |> assert_has("body .phx-connected")
    |> evaluate(visible_js("new-prefix"), &assert(&1 == false))
    |> visit("/network/prefixes/#{context.hall.id}")
    |> assert_has("body .phx-connected")
    |> evaluate(visible_js("edit-prefix"), &assert(&1 == false))
    |> evaluate(visible_js("delete-prefix"), &assert(&1 == false))
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
    |> evaluate(
      "document.documentElement.scrollWidth <= document.documentElement.clientWidth",
      &assert(&1 == true)
    )
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

  defp visible_js(id), do: "document.getElementById('#{id}').checkVisibility()"
end
