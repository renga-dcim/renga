defmodule RengaWeb.VlanLiveTest do
  use RengaWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Renga.AccountsFixtures
  import Renga.InventoryFixtures

  alias Renga.Accounts
  alias Renga.Inventory
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

  test "lists VLANs and filters them by namespace", %{conn: conn, scope: scope} do
    {:ok, first_group} = create_group(scope, "prod", [{1, 100}])
    {:ok, second_group} = create_group(scope, "lab", [{200, 300}])
    {:ok, first_vlan} = create_vlan(scope, first_group, 10, "Management")
    {:ok, second_vlan} = create_vlan(scope, second_group, 250, "Lab access")

    {:ok, view, _html} = live(conn, ~p"/ipam/vlans")

    assert has_element?(view, "#vlan-#{first_vlan.id}", "Management")
    assert has_element?(view, "#vlan-#{second_vlan.id}", "Lab access")
    assert has_element?(view, "#vlans-list [data-vlan-vid='10']")
    assert has_element?(view, "#vlan-form")

    view
    |> form("#vlan-filters", filters: %{group_id: first_group.id})
    |> render_change()

    assert_patch(view, ~p"/ipam/vlans?#{[group_id: first_group.id]}")

    assert has_element?(view, "#vlan-#{first_vlan.id}")
    refute has_element?(view, "#vlan-#{second_vlan.id}")

    view
    |> form("#vlan-filters", filters: %{group_id: "global"})
    |> render_change()

    assert_patch(view, ~p"/ipam/vlans?#{[group_id: "global"]}")

    refute has_element?(view, "#vlan-#{first_vlan.id}")
    refute has_element?(view, "#vlan-#{second_vlan.id}")
  end

  test "shows desired and observed interface membership separately", %{
    conn: conn,
    scope: scope
  } do
    {:ok, group} = create_group(scope, "membership", [{1, 100}])
    {:ok, vlan} = create_vlan(scope, group, 10, "Management")

    {:ok, resource} =
      Inventory.create_resource(scope, %{
        kind: "server",
        name: "membership-server",
        lifecycle_state: "active"
      })

    {:ok, interface} = Inventory.create_interface(scope, resource.id, %{name: "eth0"})
    {:ok, source} = Inventory.create_source(scope, %{kind: "manual", name: "membership-source"})
    {:ok, _mapping} = Topology.put_source_vlan_group_mapping(scope, source.id, group.id)

    {:ok, _assignment} =
      Topology.put_desired_interface_vlan_assignment(scope, interface.id, vlan.id, %{
        tagging_mode: "tagged"
      })

    {:ok, _mode} = Topology.put_desired_interface_vlan_mode(scope, interface.id, %{mode: "trunk"})

    observation = observation_fixture(scope, source, "vlan-ui-membership", %{})

    assert {:ok, [_evidence]} =
             Topology.reconcile_interface_vlans(
               scope,
               source,
               observation,
               resource.id,
               [%{"name" => "eth0", "vlans" => [%{"vid" => 10, "tagging_mode" => "tagged"}]}],
               true
             )

    {:ok, view, _html} = live(conn, ~p"/ipam/vlans?#{[interface_id: interface.id]}")

    assert has_element?(view, "#interface-membership", "eth0")
    assert has_element?(view, "#interface-membership", "membership-server")

    assert has_element?(
             view,
             "#interface-membership a[href='/inventory/resources/#{resource.id}']"
           )

    assert has_element?(view, "#desired-memberships", "10 · Management")
    assert has_element?(view, "#current-memberships", "10 · Management")
    assert has_element?(view, "#interface-membership", "trunk")
    assert has_element?(view, "#vlans-clear-interface")

    # Without the filter the membership panel is absent.
    {:ok, plain_view, _html} = live(conn, ~p"/ipam/vlans")
    refute has_element?(plain_view, "#interface-membership")
  end

  test "managers create a VLAN and members only read it", %{
    conn: conn,
    organization: organization,
    scope: scope
  } do
    {:ok, group} = create_group(scope, "authoring", [{1, 100}])

    {:ok, view, _html} = live(conn, ~p"/ipam/vlans")

    view
    |> form("#vlan-form",
      vlan: %{
        vlan_group_id: group.id,
        vid: "10",
        name: "Management",
        status: "active",
        role: "management",
        description: ""
      }
    )
    |> render_submit()

    assert has_element?(view, "#flash-info", "VLAN 10 created")
    assert has_element?(view, "#vlans-list", "Management")

    assert [vlan] = Topology.list_vlans(scope, group.id)
    assert vlan.vid == 10

    member = user_fixture()
    organization_membership_fixture(member, organization, %{role: "member"})

    member_conn =
      build_conn()
      |> log_in_user(member)
      |> put_session(:current_organization_id, organization.id)

    {:ok, member_view, _html} = live(member_conn, ~p"/ipam/vlans")

    assert has_element?(member_view, "#vlan-#{vlan.id}", "Management")
    refute has_element?(member_view, "#vlan-form")
  end

  test "rejects a VID outside the selected namespace", %{conn: conn, scope: scope} do
    {:ok, group} = create_group(scope, "bounded", [{1, 100}])

    {:ok, view, _html} = live(conn, ~p"/ipam/vlans")

    view
    |> form("#vlan-form",
      vlan: %{
        vlan_group_id: group.id,
        vid: "250",
        name: "Outside",
        status: "active",
        role: "",
        description: ""
      }
    )
    |> render_submit()

    assert has_element?(view, "#flash-error", "outside the selected namespace range")
    assert Topology.list_vlans(scope, group.id) == []
  end

  test "requires authentication" do
    assert {:error, {:redirect, %{to: path}}} = live(build_conn(), ~p"/ipam/vlans")
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

  defp observation_fixture(scope, source, key, payload) do
    {:ok, observation} =
      Inventory.create_observation(scope, source.id, %{
        idempotency_key: key,
        observed_at: ~U[2026-09-08 14:00:00Z],
        payload: payload
      })

    observation
  end
end
