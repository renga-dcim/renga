defmodule RengaWeb.Browser.PrefixesTest do
  @moduledoc """
  The prefix views in a real browser: a container's space map opens the
  child a cell stands for, a prefix, a planning level, and the next free
  child or host are created from side panels, and at phone width long IPv6 prefixes keep their usage beside
  or below them, the addressing plan and findings wrap instead of
  scrolling, and the edit controls are hidden because prefixes are not
  edited on a phone.
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

  test "an admin adds a planning level from the plan panel", context do
    context.conn
    |> visit("/network/prefixes?family=ipv6")
    |> assert_has("body .phx-connected")
    |> PhoenixTest.Playwright.click("#edit-plan")
    |> assert_has("#plan-panel [role=dialog]", text: "Addressing plan")
    |> fill_in("#plan-level-form input[name='plan_level[prefix_length]']", "Prefix length",
      with: "52"
    )
    |> fill_in("#plan-level-form input[name='plan_level[name]']", "Each block is a", with: "zone")
    |> PhoenixTest.Playwright.click("#add-plan-level")
    |> assert_has("#flash-info", text: "/52 zone added to the plan")
    |> assert_has("#plan-panel-ipv6", text: "zone")
    |> assert_has("#addressing-plan-ipv6", text: "/52 zone")
    |> visit("/network/prefixes/#{context.site.id}")
    |> assert_has("#prefix-space-summary", text: "1 of 16 zone /52s allocated")
  end

  test "an admin takes the next free child and then a host from the panel", context do
    context.conn
    |> visit("/network/prefixes/#{context.site.id}")
    |> assert_has("body .phx-connected")
    |> PhoenixTest.Playwright.click("#next-free")
    |> assert_has("#next-free-panel [role=dialog]", text: "Next free")
    |> assert_has("#next-free-preview", text: "Next free: 2001:db8:a::/56")
    |> PhoenixTest.Playwright.click("#allocate")
    |> assert_has("#flash-info", text: "Allocated 2001:db8:a::/56")
    |> refute_has("#next-free-panel [role=dialog]")

    leaf = prefix_fixture(context.scope, "192.0.2.0/29")

    context.conn
    |> visit("/network/prefixes/#{leaf.id}")
    |> assert_has("body .phx-connected")
    |> PhoenixTest.Playwright.click("#next-free")
    |> assert_has("#next-free-panel [role=dialog]", text: "Next free: 192.0.2.1/29")
    |> fill_in("#next-free-form input[name='next_free[dns_name]']", "DNS name (optional)",
      with: "gw.example.net"
    )
    |> PhoenixTest.Playwright.click("#allocate")
    |> assert_has("#flash-info", text: "Allocated 192.0.2.1/29")
    |> assert_has("#address-cell-1[data-state=managed]")
    # Reopen only once the panel has closed, and act only once it shows.
    |> refute_has("#next-free-panel [role=dialog]")
    |> PhoenixTest.Playwright.click("#next-free")
    |> assert_has("#next-free-panel [role=dialog]", text: "Next free: 192.0.2.2/29")
    # Switching to a child prefix swaps the fields, keeps the default
    # length, and previews a block; the managed .1 occupies the first /30.
    |> select("#next-free-form select[name='next_free[kind]']", "Allocate a",
      option: "Child prefix",
      exact: false
    )
    |> assert_has("#next-free-panel [role=dialog] input[name='next_free[length]']")
    |> refute_has("#next-free-form input[name='next_free[dns_name]']")
    |> fill_in("#next-free-form input[name='next_free[length]']", "Prefix length", with: "30")
    |> assert_has("#next-free-preview", text: "Next free: 192.0.2.4/30")
  end

  test "edit validation, save, and delete cancellation and confirmation", context do
    prefix = prefix_fixture(context.scope, "192.0.2.0/24")
    prefix_fixture(context.scope, "192.0.3.0/24")

    session =
      context.conn
      |> visit("/network/prefixes/#{prefix.id}")
      |> assert_has("body .phx-connected")
      |> PhoenixTest.Playwright.click("#edit-prefix")
      |> fill_in("#prefix-edit-form input[name='prefix[prefix]']", "CIDR", with: "192.0.3.0/24")
      |> PhoenixTest.Playwright.click("#save-prefix")
      |> assert_has("#prefix-edit-panel [role=dialog]",
        text: "already exists in this routing table"
      )
      |> fill_in("#prefix-edit-form input[name='prefix[prefix]']", "CIDR", with: "192.0.4.0/24")
      |> PhoenixTest.Playwright.click("#save-prefix")
      |> assert_has("#prefix-detail h1", text: "192.0.4.0/24")
      |> refute_has("#prefix-edit-panel [role=dialog]")
      |> PhoenixTest.Playwright.click("#delete-prefix")
      |> assert_has("#delete-prefix-dialog [role=alertdialog]", text: "Delete 192.0.4.0/24?")
      |> PhoenixTest.Playwright.click("#delete-prefix-dialog-cancel")
      |> refute_has("#delete-prefix-dialog [role=alertdialog]")

    assert Renga.IPAM.get_prefix!(context.scope, prefix.id)

    session
    |> PhoenixTest.Playwright.click("#delete-prefix")
    |> PhoenixTest.Playwright.click("#delete-prefix-dialog-confirm")
    |> assert_path("/network/prefixes", query_params: %{family: "ipv4"})

    refute Renga.Repo.get(Renga.Inventory.Prefix, prefix.id)
  end

  test "focused drafts survive broadcasts but cannot overwrite an external edit", context do
    prefix = prefix_fixture(context.scope, "192.0.2.0/24")

    session =
      context.conn
      |> visit("/network/prefixes/#{prefix.id}")
      |> assert_has("body .phx-connected")
      |> PhoenixTest.Playwright.click("#edit-prefix")
      |> fill_in("#prefix-edit-form input[name='prefix[description]']", "Description (optional)",
        with: "My draft"
      )
      |> evaluate(
        "document.querySelector('#prefix-edit-form input[name=\"prefix[description]\"]').focus()"
      )

    prefix_fixture(context.scope, "192.0.3.0/24")

    session
    |> evaluate(
      "new Promise(r => setTimeout(() => r(document.querySelector('#prefix-edit-form input[name=\"prefix[description]\"]').value), 600))",
      &assert(&1 == "My draft")
    )

    {:ok, _} = Renga.IPAM.update_prefix(context.scope, prefix, %{status: "reserved"})

    session =
      session
      |> assert_has("#prefix-detail", text: "Reserved")
      |> evaluate("document.activeElement.name", &assert(&1 == "prefix[description]"))
      |> PhoenixTest.Playwright.click("#save-prefix")
      |> assert_has("#flash-error", text: "This prefix changed elsewhere")
      |> assert_has("#prefix-edit-panel [role=dialog]")

    assert %{status: "reserved", description: nil} =
             Renga.IPAM.get_prefix!(context.scope, prefix.id)

    session
    |> PhoenixTest.Playwright.click("#reload-prefix-edit")
    |> evaluate(
      "new Promise(r => setTimeout(() => r(document.querySelector('#prefix-edit-form select[name=\"prefix[status]\"]').value), 300))",
      &assert(&1 == "reserved")
    )
    |> fill_in("#prefix-edit-form input[name='prefix[description]']", "Description (optional)",
      with: "Retry"
    )
    |> PhoenixTest.Playwright.click("#save-prefix")
    |> refute_has("#prefix-edit-panel [role=dialog]")

    assert %{status: "reserved", description: "Retry"} =
             Renga.IPAM.get_prefix!(context.scope, prefix.id)
  end

  @tag browser_context_opts: [
         has_touch: true,
         is_mobile: true,
         viewport: %{width: 390, height: 844}
       ]
  test "prefixes are readable but not editable on a phone", context do
    {:ok, _} =
      Renga.IPAM.create_plan_level(context.scope, %{
        family: "ipv6",
        prefix_length: 48,
        name: "site"
      })

    {:ok, _} =
      Renga.IPAM.create_plan_level(context.scope, %{
        family: "ipv6",
        prefix_length: 56,
        name: "hall"
      })

    {:ok, _} =
      Renga.IPAM.create_plan_level(context.scope, %{
        family: "ipv6",
        prefix_length: 64,
        name: "VLAN"
      })

    context.conn
    |> visit("/network/prefixes")
    |> assert_has("body .phx-connected")
    |> evaluate(visible_js("new-prefix"), &assert(&1 == false))
    |> evaluate(visible_js("edit-plan"), &assert(&1 == false))
    |> evaluate(visible_js("addressing-plan-ipv6"), &assert(&1 == true))
    |> evaluate(
      "document.documentElement.scrollWidth <= document.documentElement.clientWidth",
      &assert(&1 == true)
    )
    |> visit("/network/prefixes/#{context.hall.id}")
    |> assert_has("body .phx-connected")
    |> evaluate(visible_js("edit-prefix"), &assert(&1 == false))
    |> evaluate(visible_js("delete-prefix"), &assert(&1 == false))
    |> evaluate(visible_js("next-free"), &assert(&1 == false))
  end

  @tag browser_context_opts: [
         has_touch: true,
         is_mobile: true,
         viewport: %{width: 390, height: 844}
       ]
  test "a strict prefix's findings stay readable on a phone", context do
    prefix =
      prefix_fixture(context.scope, "2001:db8:a:300:1::/80", %{strict: true})

    {_host, ports} =
      device_fixture(context.scope, "server", "a-long-hostname-for-wrapping", ~w(eth0))

    address_fixture(context.scope, ports["eth0"], "2001:db8:a:300:1:abcd:ef01:2345/80")

    {_other, other_ports} =
      device_fixture(context.scope, "server", "another-long-hostname", ~w(eth0))

    address_fixture(context.scope, other_ports["eth0"], "2001:db8:a:300:1:abcd:ef01:2345/80")
    {:ok, :ok} = Renga.IPAM.AddressFindings.reconcile(context.scope.organization_id)

    [first, second | _] = Renga.Repo.all(Renga.IPAM.AddressFinding)

    {:ok, _} =
      Renga.Findings.snooze(
        context.scope,
        Renga.Findings.get_finding!(context.scope, "address", first.id),
        DateTime.add(Renga.Time.utc_now_ms(), 3600)
      )

    {:ok, _} =
      Renga.Findings.accept_exception(
        context.scope,
        Renga.Findings.get_finding!(context.scope, "address", second.id),
        %{"exception_reason" => "Temporary"}
      )

    context.conn
    |> visit("/network/prefixes/#{prefix.id}")
    |> assert_has("body .phx-connected")
    |> assert_has("#prefix-findings", text: "Unmanaged in strict prefix")
    |> assert_has("#prefix-findings", text: "Snoozed")
    |> assert_has("#prefix-findings", text: "Exception")
    |> evaluate(
      "Array.from(document.querySelectorAll('#prefix-finding-list > li > span.basis-full')).map(el => el.getBoundingClientRect().width >= 200 && el.getBoundingClientRect().height < 160)",
      fn checks ->
        assert length(checks) == 4
        assert Enum.all?(checks)
      end
    )
    |> evaluate(
      "document.documentElement.scrollWidth <= document.documentElement.clientWidth",
      &assert(&1 == true)
    )
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
