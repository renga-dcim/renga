defmodule RengaWeb.PrefixDetailLiveTest do
  use RengaWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Renga.AccountsFixtures
  import Renga.InventoryFixtures
  import Renga.TopologyFixtures

  alias Renga.Accounts
  alias Renga.Topology

  setup %{conn: conn} do
    user = user_fixture()
    organization = organization_fixture()
    organization_membership_fixture(user, organization, %{role: "admin"})
    scope = Accounts.scope_for_user(user, organization.id)

    conn =
      conn
      |> log_in_user(user)
      |> put_session(:current_organization_id, organization.id)

    {_host, ports} = device_fixture(scope, "server", "web-01", ~w(eth0))
    %{conn: conn, scope: scope, eth0: ports["eth0"]}
  end

  test "shows a container as its child space", %{conn: conn, scope: scope} do
    site = prefix_fixture(scope, "2001:db8:a::/48")
    hall = prefix_fixture(scope, "2001:db8:a::/56")
    prefix_fixture(scope, "2001:db8:a:100::/56")
    prefix_fixture(scope, "2001:db8:a:210::/64")

    {:ok, view, _html} = live(conn, ~p"/network/prefixes/#{site}")

    assert has_element?(view, "#prefix-detail", "2001:db8:a::/48")
    assert has_element?(view, "#prefix-space-summary", "3 of 256 /56s allocated")
    assert has_element?(view, "#prefix-space-map a[data-state='allocated']", "2001:db8:a::/56")
    assert has_element?(view, "#prefix-space-map a[data-state='partial']")
    assert has_element?(view, "#prefix-space-map span[data-state='free']")
    assert has_element?(view, "#prefix-properties sup", "80")

    {:error, {:live_redirect, %{to: path}}} =
      view |> element("#prefix-space-map a[title='2001:db8:a::/56']") |> render_click()

    assert path == "/network/prefixes/#{hall.id}"
  end

  test "maps every address of a small IPv4 leaf", %{conn: conn, scope: scope, eth0: eth0} do
    site = prefix_fixture(scope, "192.0.2.0/24")
    lan = prefix_fixture(scope, "192.0.2.0/28")
    address_fixture(scope, eth0, "192.0.2.5")

    {:ok, view, _html} = live(conn, ~p"/network/prefixes/#{lan}")

    assert has_element?(view, "#prefix-detail nav a[href='/network/prefixes/#{site.id}']")
    assert has_element?(view, "#prefix-utilization", "7%")
    assert has_element?(view, "#prefix-utilization", "1 of 14")
    assert has_element?(view, "#address-cell-0[data-state='network']")
    assert has_element?(view, "#address-cell-5[data-state='used'][title*='web-01']")
    assert has_element?(view, "#address-cell-15[data-state='broadcast']")
    assert has_element?(view, "#prefix-used-addresses", "192.0.2.5")
  end

  test "lists an IPv6 leaf's addresses with assignment, hiding temporary ones", %{
    conn: conn,
    scope: scope,
    eth0: eth0
  } do
    lan = prefix_fixture(scope, "2001:db8:a:10::/64")
    static = address_fixture(scope, eth0, "2001:db8:a:10::15", %{"assignment" => "static"})
    slaac = address_fixture(scope, eth0, "2001:db8:a:10:21b:21ff:fe3c:4d5e")

    temporary =
      address_fixture(scope, eth0, "2001:db8:a:10:a1b2:c3d4:e5f6:1", %{"temporary" => true})

    {:ok, view, _html} = live(conn, ~p"/network/prefixes/#{lan}")

    assert has_element?(view, "#prefix-address-count", "3 addresses observed, 1 temporary hidden")
    assert has_element?(view, "#address-#{static.id}", "::15")
    assert has_element?(view, "#address-#{static.id} .text-fg-subtle", "2001:db8:a:10")
    assert has_element?(view, "#address-#{slaac.id} .text-fg-subtle", "2001:db8:a:10:")
    assert has_element?(view, "#prefix-addresses [data-method='static']", "Static")
    assert has_element?(view, "#address-#{slaac.id}")
    assert has_element?(view, "#prefix-addresses [data-method='slaac']", "SLAAC")
    refute has_element?(view, "#address-#{temporary.id}")

    view |> element("#prefix-toggle-temporary") |> render_click()
    assert_patch(view, ~p"/network/prefixes/#{lan}?temporary=show")
    assert has_element?(view, "#address-#{temporary.id}[data-temporary='true']", "temporary")
  end

  test "classifies reconciled DHCPv6 and hides reconciled temporary evidence by default", %{
    conn: conn,
    scope: scope
  } do
    lan = prefix_fixture(scope, "2001:db8:1::/80")
    {:ok, source} = Renga.Inventory.create_source(scope, %{kind: "host_agent", name: "ipv6"})

    [dhcp, temporary] =
      report_addresses(scope, source, [
        %{"address" => "2001:db8:1::15/64", "metadata" => %{"assignment" => "dhcpv6"}},
        %{"address" => "2001:db8:1::99/64", "metadata" => %{"temporary" => true}}
      ])
      |> Enum.sort_by(& &1.address.address)

    {:ok, view, _html} = live(conn, ~p"/network/prefixes/#{lan}")
    assert has_element?(view, "#address-#{dhcp.id}")
    assert has_element?(view, "#prefix-addresses [data-method='dhcp']", "DHCPv6")
    refute has_element?(view, "#address-#{temporary.id}")
    view |> element("#prefix-toggle-temporary") |> render_click()
    assert has_element?(view, "#address-#{temporary.id}[data-temporary='true']")
  end

  test "names counterparts on the same VLAN or marks the prefix single-stack", %{
    conn: conn,
    scope: scope
  } do
    group = vlan_group_fixture(scope, "detail-pairing")
    users = vlan_fixture(scope, group, 10, "users")
    voice = vlan_fixture(scope, group, 20, "voice")
    users_v4 = prefix_fixture(scope, "10.0.10.0/24")
    users_v6 = prefix_fixture(scope, "2001:db8:a:10::/64")
    voice_v4 = prefix_fixture(scope, "10.0.20.0/24")
    {:ok, _} = Topology.attach_prefix_vlan(scope, users_v4.id, users.id)
    {:ok, _} = Topology.attach_prefix_vlan(scope, users_v6.id, users.id)
    {:ok, _} = Topology.attach_prefix_vlan(scope, voice_v4.id, voice.id)

    {:ok, view, _html} = live(conn, ~p"/network/prefixes/#{users_v4}")
    assert has_element?(view, "#prefix-vlans a[href='/network/vlans/#{users.id}']")
    assert has_element?(view, "#prefix-counterparts", "2001:db8:a:10::/64")
    refute has_element?(view, "#prefix-single-stack")

    {:ok, voice_view, _html} = live(conn, ~p"/network/prefixes/#{voice_v4}")
    assert has_element?(voice_view, "#prefix-single-stack", "no IPv6 prefix")
  end

  test "keeps another organization's prefix out of reach", %{conn: conn} do
    other = user_fixture()
    other_organization = organization_fixture()
    organization_membership_fixture(other, other_organization, %{role: "admin"})
    other_scope = Accounts.scope_for_user(other, other_organization.id)
    foreign = prefix_fixture(other_scope, "198.51.100.0/24")

    assert_raise Ecto.NoResultsError, fn -> live(conn, ~p"/network/prefixes/#{foreign}") end
  end
end
