defmodule RengaWeb.VlanGroupLiveTest do
  use RengaWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Renga.AccountsFixtures
  import Renga.InventoryFixtures

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

    %{conn: conn, organization: organization, scope: scope}
  end

  test "lists VLAN groups with utilization and links to their VLANs", %{conn: conn, scope: scope} do
    {:ok, group} = create_group(scope, "production", [{1, 100}])
    {:ok, _vlan} = create_vlan(scope, group, 10, "Management")
    {:ok, _vlan} = create_vlan(scope, group, 20, "Storage")

    {:ok, view, _html} = live(conn, ~p"/ipam/vlan-groups")

    assert has_element?(view, "#vlan-groups")
    assert has_element?(view, "#vlan-group-#{group.id}", "production")
    assert has_element?(view, "#vlan-group-#{group.id}", "2 of 100 VIDs assigned")
    assert has_element?(view, "#vlan-group-#{group.id}[data-scope-kind='global']")

    assert has_element?(
             view,
             "#vlan-group-#{group.id} [data-vid-range='#{hd(group.vid_ranges).id}']"
           )

    assert has_element?(
             view,
             "#vlan-group-#{group.id} a[href='/ipam/vlans?group_id=#{group.id}']"
           )

    assert has_element?(view, "#vlan-group-form")
  end

  test "keeps another organization's VLAN groups invisible", %{conn: conn, scope: scope} do
    {:ok, group} = create_group(scope, "local", [{1, 10}])

    foreign_user = user_fixture()
    foreign_organization = organization_fixture()
    organization_membership_fixture(foreign_user, foreign_organization, %{role: "admin"})
    foreign_scope = Accounts.scope_for_user(foreign_user, foreign_organization.id)
    {:ok, foreign_group} = create_group(foreign_scope, "foreign", [{1, 10}])

    {:ok, view, _html} = live(conn, ~p"/ipam/vlan-groups")

    assert has_element?(view, "#vlan-group-#{group.id}")
    refute has_element?(view, "#vlan-group-#{foreign_group.id}")
  end

  test "managers create a namespace through the form and members only read it", %{
    conn: conn,
    organization: organization,
    scope: scope
  } do
    {:ok, view, _html} = live(conn, ~p"/ipam/vlan-groups")

    refute has_element?(view, "#vlan-groups-list article")

    view
    |> form("#vlan-group-form",
      vlan_group: %{
        name: "Campus",
        slug: "",
        scope: "global",
        start_vid: "1",
        end_vid: "200",
        description: "Campus access VLANs"
      }
    )
    |> render_submit()

    assert has_element?(view, "#flash-info", "campus")
    assert has_element?(view, "#vlan-groups-list", "Campus")

    assert [group] = Topology.list_vlan_groups(scope)
    assert group.slug == "campus"
    assert [%{start_vid: 1, end_vid: 200}] = group.vid_ranges

    member = user_fixture()
    organization_membership_fixture(member, organization, %{role: "member"})

    member_conn =
      build_conn()
      |> log_in_user(member)
      |> put_session(:current_organization_id, organization.id)

    {:ok, member_view, _html} = live(member_conn, ~p"/ipam/vlan-groups")

    assert has_element?(member_view, "#vlan-group-#{group.id}", "Campus")
    refute has_element?(member_view, "#vlan-group-form")
  end

  test "rejects an invalid VID range without creating a namespace", %{conn: conn, scope: scope} do
    {:ok, view, _html} = live(conn, ~p"/ipam/vlan-groups")

    view
    |> form("#vlan-group-form",
      vlan_group: %{
        name: "Broken",
        slug: "broken",
        scope: "global",
        start_vid: "300",
        end_vid: "100",
        description: ""
      }
    )
    |> render_submit()

    assert has_element?(view, "#flash-error", "start at or below end")
    refute has_element?(view, "#vlan-groups-list article")
    assert Topology.list_vlan_groups(scope) == []
  end

  test "requires authentication", %{scope: scope} do
    {:ok, _group} = create_group(scope, "private", [{1, 10}])

    assert {:error, {:redirect, %{to: path}}} = live(build_conn(), ~p"/ipam/vlan-groups")
    assert path =~ "/users/log-in"
  end

  defp create_group(scope, name, ranges) do
    Topology.create_vlan_group(
      scope,
      %{name: name, lifecycle_state: "active"},
      %{slug: name, scope_kind: "global", status: "active"},
      Enum.map(ranges, fn {start_vid, end_vid} -> %{start_vid: start_vid, end_vid: end_vid} end)
    )
  end

  defp create_vlan(scope, group, vid, name) do
    Topology.create_vlan(
      scope,
      %{lifecycle_state: "active"},
      %{vlan_group_id: group.id, vid: vid, name: name, status: "active"}
    )
  end
end
