defmodule RengaWeb.VlanDetailLiveTest do
  use RengaWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Renga.AccountsFixtures
  import Renga.InventoryFixtures
  import Renga.TopologyFixtures

  alias Renga.Accounts
  alias Renga.Inventory
  alias Renga.Inventory.Prefix
  alias Renga.Repo
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

    group = vlan_group_fixture(scope, "detail-#{System.unique_integer([:positive])}")
    vlan = vlan_fixture(scope, group, 10, "users")

    %{conn: conn, organization: organization, scope: scope, group: group, vlan: vlan}
  end

  test "compares planned and observed membership per interface", %{
    conn: conn,
    scope: scope,
    group: group,
    vlan: vlan
  } do
    {leaf, ports} = device_fixture(scope, "switch", "detail-leaf", ~w(swp1 swp2 swp3))
    desire_vlans(scope, ports["swp1"], "access", vlan)
    desire_vlans(scope, ports["swp2"], "access", vlan)

    report_vlans(scope, leaf, group, %{
      "swp1" => {"access", [{10, "untagged"}]},
      "swp3" => {"trunk", [{10, "tagged"}]}
    })

    {:ok, view, _html} = live(conn, ~p"/network/vlans/#{vlan}")

    assert has_element?(view, "#vlan-detail", "10 · users")
    assert has_element?(view, "#vlan-properties", group.resource.name)
    assert has_element?(view, "#member-#{ports["swp1"].id} [data-member-state='both']")
    assert has_element?(view, "#member-#{ports["swp2"].id} [data-member-state='planned_only']")
    assert has_element?(view, "#member-#{ports["swp3"].id} [data-member-state='observed_only']")
    assert has_element?(view, "#vlan-member-summary", "1 agree")

    view |> element("#vlan-members-differences") |> render_click()
    assert_patch(view, ~p"/network/vlans/#{vlan}?show=differences")

    refute has_element?(view, "#member-#{ports["swp1"].id}")
    assert has_element?(view, "#member-#{ports["swp2"].id}")
    assert has_element?(view, "#member-#{ports["swp3"].id}")
  end

  test "refreshes membership under sustained traffic without losing Differences filter", %{
    conn: conn,
    scope: scope,
    vlan: vlan
  } do
    {_leaf, ports} = device_fixture(scope, "switch", "live-leaf", ~w(swp1))
    port = ports["swp1"]
    {:ok, view, _} = live(conn, ~p"/network/vlans/#{vlan}?show=differences")
    desire_vlans(scope, port, "access", vlan)

    for _ <- 1..7 do
      send(view.pid, {:inventory_changed, scope.organization_id})
      Process.sleep(100)
    end

    assert has_element?(view, "#member-#{port.id} [data-member-state=planned_only]")
    assert has_element?(view, "#vlan-members-differences[aria-current]")
  end

  test "managers link and unlink IP prefixes", %{conn: conn, scope: scope, vlan: vlan} do
    prefix = create_prefix(scope, "detail-prefix", "192.0.2.0/24")

    {:ok, view, _html} = live(conn, ~p"/network/vlans/#{vlan}")
    assert has_element?(view, "#vlan-prefixes-empty")

    view
    |> form("#prefix-vlan-form", prefix_vlan: %{prefix_id: prefix.id})
    |> render_submit()

    assert has_element?(view, "#flash-info", "Linked IP prefix 192.0.2.0/24")
    assert has_element?(view, "#vlan-prefix-#{prefix.id}", "192.0.2.0/24")
    assert [%Prefix{}] = Topology.list_vlan_prefixes(scope, vlan.id)

    # A linked prefix is no longer offered.
    refute has_element?(view, "#prefix-vlan-form option[value='#{prefix.id}']")
    assert has_element?(view, "#prefix-vlan-form-submit[disabled]")

    view |> element("#vlan-prefix-#{prefix.id}-detach") |> render_click()

    assert has_element?(view, "#flash-info", "Unlinked the IP prefix")
    refute has_element?(view, "#vlan-prefix-#{prefix.id}")
    assert Topology.list_vlan_prefixes(scope, vlan.id) == []
    assert [%Prefix{}] = Inventory.list_prefixes(scope)
  end

  test "members read prefixes without changing them", %{
    organization: organization,
    scope: scope,
    vlan: vlan
  } do
    prefix = create_prefix(scope, "detail-member-prefix", "192.0.2.0/24")
    {:ok, _relationship} = Topology.attach_prefix_vlan(scope, prefix.id, vlan.id)

    member = user_fixture()
    organization_membership_fixture(member, organization, %{role: "member"})

    member_conn =
      build_conn()
      |> log_in_user(member)
      |> put_session(:current_organization_id, organization.id)

    {:ok, view, _html} = live(member_conn, ~p"/network/vlans/#{vlan}")

    assert has_element?(view, "#vlan-prefix-#{prefix.id}", "192.0.2.0/24")
    refute has_element?(view, "#prefix-vlan-form")
    refute has_element?(view, "#vlan-prefix-#{prefix.id}-detach")
  end

  test "explains when no prefix can be linked", %{conn: conn, vlan: vlan} do
    {:ok, view, _html} = live(conn, ~p"/network/vlans/#{vlan}")

    assert has_element?(view, "#prefix-vlan-form-empty", "No other IP prefixes are recorded.")
    assert has_element?(view, "#prefix-vlan-form-submit[disabled]")
  end

  test "recovers when the chosen prefix is deleted after the form loads", %{
    conn: conn,
    scope: scope,
    vlan: vlan
  } do
    prefix = create_prefix(scope, "stale-prefix", "192.0.2.0/24")
    {:ok, view, _html} = live(conn, ~p"/network/vlans/#{vlan}")

    Repo.delete!(prefix)

    view
    |> form("#prefix-vlan-form", prefix_vlan: %{prefix_id: prefix.id})
    |> render_submit()

    assert has_element?(view, "#flash-error", "no longer available")
    assert Topology.list_vlan_prefixes(scope, vlan.id) == []
    assert has_element?(view, "#prefix-vlan-form")
  end

  test "treats malformed prefix ids as missing instead of crashing", %{conn: conn, vlan: vlan} do
    {:ok, view, _html} = live(conn, ~p"/network/vlans/#{vlan}")

    render_submit(view, "attach_prefix", %{"prefix_vlan" => %{"prefix_id" => "not-a-uuid"}})
    assert has_element?(view, "#flash-error", "no longer available")

    render_click(view, "detach_prefix", %{"prefix-id" => "not-a-uuid"})
    assert has_element?(view, "#flash-error", "no longer available")
  end

  test "keeps another organization's VLANs and prefixes out of reach", %{
    conn: conn,
    scope: scope,
    vlan: vlan
  } do
    foreign_user = user_fixture()
    foreign_organization = organization_fixture()
    organization_membership_fixture(foreign_user, foreign_organization, %{role: "admin"})
    foreign_scope = Accounts.scope_for_user(foreign_user, foreign_organization.id)
    foreign_group = vlan_group_fixture(foreign_scope, "foreign-detail")
    foreign_vlan = vlan_fixture(foreign_scope, foreign_group, 10, "foreign")
    foreign_prefix = create_prefix(foreign_scope, "foreign-detail-prefix", "198.51.100.0/24")
    own_prefix = create_prefix(scope, "own-detail-prefix", "192.0.2.0/24")

    assert_raise Ecto.NoResultsError, fn -> live(conn, ~p"/network/vlans/#{foreign_vlan}") end

    {:ok, view, _html} = live(conn, ~p"/network/vlans/#{vlan}")
    assert has_element?(view, "#prefix-vlan-form option[value='#{own_prefix.id}']")
    refute has_element?(view, "#prefix-vlan-form option[value='#{foreign_prefix.id}']")
  end

  test "requires authentication", %{vlan: vlan} do
    assert {:error, {:redirect, %{to: path}}} = live(build_conn(), ~p"/network/vlans/#{vlan}")
    assert path =~ "/users/log-in"
  end

  defp create_prefix(scope, _resource_name, cidr) do
    {:ok, prefix} = Renga.IPAM.create_prefix(scope, %{prefix: cidr})
    prefix
  end
end
