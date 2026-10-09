defmodule RengaWeb.PrefixLiveTest do
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
    organization_membership_fixture(user, organization, %{role: "member"})

    admin = user_fixture()
    organization_membership_fixture(admin, organization, %{role: "admin"})
    scope = Accounts.scope_for_user(admin, organization.id)

    conn =
      conn
      |> log_in_user(user)
      |> put_session(:current_organization_id, organization.id)

    %{conn: conn, scope: scope}
  end

  defp plan(scope) do
    group = vlan_group_fixture(scope, "prefix-ui-#{System.unique_integer([:positive])}")
    users = vlan_fixture(scope, group, 10, "users")
    voice = vlan_fixture(scope, group, 20, "voice")

    site_v4 = prefix_fixture(scope, "10.0.0.0/16")
    users_v4 = prefix_fixture(scope, "10.0.10.0/24")
    voice_v4 = prefix_fixture(scope, "10.0.20.0/24")
    site_v6 = prefix_fixture(scope, "2001:db8:a::/48")
    users_v6 = prefix_fixture(scope, "2001:db8:a:10::/64")
    blue = prefix_fixture(scope, "172.16.0.0/24", %{vrf: "blue"})

    {:ok, _} = Topology.attach_prefix_vlan(scope, users_v4.id, users.id)
    {:ok, _} = Topology.attach_prefix_vlan(scope, users_v6.id, users.id)
    {:ok, _} = Topology.attach_prefix_vlan(scope, voice_v4.id, voice.id)

    %{
      site_v4: site_v4,
      users_v4: users_v4,
      voice_v4: voice_v4,
      site_v6: site_v6,
      users_v6: users_v6,
      blue: blue
    }
  end

  test "shows each family's tree side by side", %{conn: conn, scope: scope} do
    p = plan(scope)

    {:ok, view, _html} = live(conn, ~p"/network/prefixes")

    assert has_element?(view, "#area-tabs a[aria-current=page]", "Prefixes")
    assert has_element?(view, "#prefix-tree-ipv4 #prefix-row-#{p.site_v4.id}")
    assert has_element?(view, "#prefix-tree-ipv4 #prefix-row-#{p.users_v4.id}")
    assert has_element?(view, "#prefix-tree-ipv6 #prefix-row-#{p.users_v6.id}")
    refute has_element?(view, "#prefix-tree-ipv4 #prefix-row-#{p.users_v6.id}")

    assert has_element?(view, "#prefix-row-#{p.site_v4.id}-usage[data-usage='children']", "2")
    assert has_element?(view, "#prefix-row-#{p.users_v4.id}-usage[data-usage='percent']", "0%")
    assert has_element?(view, "#prefix-row-#{p.users_v6.id}-usage[data-usage='count']")
    refute has_element?(view, "#prefix-row-#{p.blue.id}")
  end

  test "links counterparts and highlights both when one is selected", %{conn: conn, scope: scope} do
    p = plan(scope)

    {:ok, view, _html} = live(conn, ~p"/network/prefixes")

    assert has_element?(view, "#prefix-row-#{p.voice_v4.id}-single-stack", "IPv4 only")
    refute has_element?(view, "#prefix-row-#{p.users_v4.id}-single-stack")

    view |> element("#prefix-row-#{p.users_v4.id}-pair-#{p.users_v6.id}") |> render_click()
    assert_patch(view, ~p"/network/prefixes?#{[selected: p.users_v4.id]}")

    assert has_element?(view, "#prefix-row-#{p.users_v4.id}[data-highlighted='true']")
    assert has_element?(view, "#prefix-row-#{p.users_v6.id}[data-highlighted='true']")
    assert has_element?(view, "#prefix-row-#{p.voice_v4.id}[data-highlighted='false']")
  end

  test "switches address family and routing table for the whole view", %{
    conn: conn,
    scope: scope
  } do
    p = plan(scope)

    {:ok, view, _html} = live(conn, ~p"/network/prefixes")

    view |> element("#prefix-family-ipv6") |> render_click()
    assert_patch(view, ~p"/network/prefixes?#{[family: :ipv6]}")
    refute has_element?(view, "#prefix-tree-ipv4")
    assert has_element?(view, "#prefix-row-#{p.users_v6.id}")

    view |> form("#prefix-table", table: %{vrf: "blue"}) |> render_change()
    assert_patch(view, ~p"/network/prefixes?#{[family: :ipv6, vrf: "blue"]}")
    assert has_element?(view, "#prefix-tree-ipv6-empty", "No IPv6 prefixes in blue")

    view |> element("#prefix-family-ipv4") |> render_click()
    assert has_element?(view, "#prefix-row-#{p.blue.id}")
    refute has_element?(view, "#prefix-row-#{p.users_v4.id}")
  end

  test "ignores an unknown routing table", %{conn: conn, scope: scope} do
    p = plan(scope)
    {:ok, view, _html} = live(conn, ~p"/network/prefixes?vrf=nope")
    assert has_element?(view, "#prefix-row-#{p.users_v4.id}")
  end

  test "names a VRF regardless of case and follows its rename", %{conn: conn, scope: scope} do
    p = plan(scope)
    {:ok, view, _html} = live(conn, ~p"/network/prefixes?vrf=BLUE")

    assert has_element?(view, "#prefix-row-#{p.blue.id}")
    assert has_element?(view, "#prefix-table option[selected][value='blue']")

    {:ok, _} = Renga.IPAM.update_vrf(scope, p.blue.vrf, %{name: "Tenant"})
    send(view.pid, :reload)

    assert_patch(view, ~p"/network/prefixes?vrf=Tenant")
    assert has_element?(view, "#prefix-row-#{p.blue.id}")
    assert has_element?(view, "#prefix-table option[selected][value='Tenant']")
  end

  test "keeps another organization's prefixes invisible", %{conn: conn} do
    other = user_fixture()
    other_organization = organization_fixture()
    organization_membership_fixture(other, other_organization, %{role: "admin"})
    other_scope = Accounts.scope_for_user(other, other_organization.id)
    foreign = prefix_fixture(other_scope, "198.51.100.0/24")
    foreign_green = prefix_fixture(other_scope, "198.51.100.0/24", %{vrf: "green"})

    {:ok, view, _html} = live(conn, ~p"/network/prefixes")
    refute has_element?(view, "#prefix-row-#{foreign.id}")
    assert has_element?(view, "#prefix-tree-ipv4-empty")

    # Their VRFs are neither listed nor reachable by name.
    {:ok, view, _html} = live(conn, ~p"/network/prefixes?vrf=green")
    refute has_element?(view, "#prefix-table option[value='green']")
    refute has_element?(view, "#prefix-row-#{foreign_green.id}")
  end

  test "requires authentication" do
    assert {:error, {:redirect, %{to: path}}} = live(build_conn(), ~p"/network/prefixes")
    assert path =~ "/users/log-in"
  end
end
