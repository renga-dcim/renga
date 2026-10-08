defmodule RengaWeb.VlanLiveTest do
  use RengaWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Renga.AccountsFixtures
  import Renga.InventoryFixtures
  import Renga.TopologyFixtures

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

    {:ok, view, _html} = live(conn, ~p"/network/vlans")

    assert has_element?(view, "#vlan-#{first_vlan.id}", "Management")
    assert has_element?(view, "#vlan-#{second_vlan.id}", "Lab access")
    assert has_element?(view, "#vlans-list [data-vlan-vid='10']")
    assert has_element?(view, "#vlan-form")

    view
    |> form("#vlan-filters", filters: %{group_id: first_group.id})
    |> render_change()

    assert_patch(view, ~p"/network/vlans?#{[group_id: first_group.id]}")

    assert has_element?(view, "#vlan-#{first_vlan.id}")
    refute has_element?(view, "#vlan-#{second_vlan.id}")

    view
    |> form("#vlan-filters", filters: %{group_id: "global"})
    |> render_change()

    assert_patch(view, ~p"/network/vlans?#{[group_id: "global"]}")

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

    {:ok, view, _html} = live(conn, ~p"/network/vlans?#{[interface_id: interface.id]}")

    assert has_element?(view, "#interface-membership", "eth0")
    assert has_element?(view, "#interface-membership", "membership-server")

    assert has_element?(
             view,
             "#interface-membership a[href='/inventory/#{resource.id}']"
           )

    assert has_element?(view, "#desired-memberships", "10 · Management")
    assert has_element?(view, "#current-memberships", "10 · Management")
    assert has_element?(view, "#interface-membership-desired-mode", "Trunk")

    # Membership evidence exists without mode evidence, so the panel reports the reconciled
    # mode as unavailable instead of inventing a mode or denying the membership evidence.
    assert has_element?(
             view,
             "#interface-membership-observed-mode > dd p",
             "Membership was observed; no reconciled port mode is available."
           )

    assert has_element?(view, "#interface-membership-observed-mode", "Unavailable")
    refute has_element?(view, "#interface-membership-observed-mode", "trunk")
    assert has_element?(view, "#vlans-clear-interface")

    # Without the filter the membership panel is absent.
    {:ok, plain_view, _html} = live(conn, ~p"/network/vlans")
    refute has_element?(plain_view, "#interface-membership")
  end

  test "shows a reported observed mode without the missing-mode note", %{conn: conn, scope: scope} do
    {:ok, group} = create_group(scope, "observed-mode", [{1, 100}])
    {:ok, _vlan} = create_vlan(scope, group, 10, "Management")

    {:ok, resource} =
      Inventory.create_resource(scope, %{
        kind: "server",
        name: "observed-mode-server",
        lifecycle_state: "active"
      })

    {:ok, interface} = Inventory.create_interface(scope, resource.id, %{name: "eth0"})
    {:ok, source} = Inventory.create_source(scope, %{kind: "manual", name: "mode-source"})
    {:ok, _mapping} = Topology.put_source_vlan_group_mapping(scope, source.id, group.id)

    observation = observation_fixture(scope, source, "vlan-ui-mode", %{})

    assert {:ok, [_evidence]} =
             Topology.reconcile_interface_vlans(
               scope,
               source,
               observation,
               resource.id,
               [
                 %{
                   "name" => "eth0",
                   "vlans" => [%{"vid" => 10, "tagging_mode" => "tagged"}],
                   "vlan_mode" => "trunk"
                 }
               ],
               true
             )

    {:ok, view, _html} = live(conn, ~p"/network/vlans?#{[interface_id: interface.id]}")

    assert has_element?(view, "#interface-membership-observed-mode", "Trunk")
    refute has_element?(view, "#interface-membership-observed-mode", "Unavailable")
    refute has_element?(view, "#interface-membership-observed-mode > dd p")
  end

  test "does not claim no mode was reported when conflicting evidence suppresses it", %{
    conn: conn,
    scope: scope
  } do
    {:ok, group} = create_group(scope, "conflicting-mode", [{1, 100}])
    {:ok, _vlan} = create_vlan(scope, group, 10, "Tagged")

    {:ok, resource} =
      Inventory.create_resource(scope, %{
        kind: "server",
        name: "conflicting-mode-server",
        lifecycle_state: "active"
      })

    {:ok, interface} = Inventory.create_interface(scope, resource.id, %{name: "eth0"})

    {:ok, source_a} = Inventory.create_source(scope, %{kind: "manual", name: "mode-source-a"})
    {:ok, source_b} = Inventory.create_source(scope, %{kind: "manual", name: "mode-source-b"})
    {:ok, _mapping} = Topology.put_source_vlan_group_mapping(scope, source_a.id, group.id)
    {:ok, _mapping} = Topology.put_source_vlan_group_mapping(scope, source_b.id, group.id)

    first = observation_fixture(scope, source_a, "conflict-mode-a", %{})

    assert {:ok, [_evidence]} =
             Topology.reconcile_interface_vlans(
               scope,
               source_a,
               first,
               resource.id,
               [
                 %{
                   "name" => "eth0",
                   "vlan_mode" => "trunk",
                   "vlans" => [%{"vid" => 10, "tagging_mode" => "tagged"}]
                 }
               ],
               true
             )

    assert %{mode: "trunk"} = Topology.get_current_interface_vlan_mode(scope, interface.id)

    # A second source reports access with no memberships, which cannot reconcile against the
    # tagged membership, so the current mode is dropped while mode evidence was reported.
    incompatible = observation_fixture(scope, source_b, "conflict-mode-b", %{})

    assert {:ok, []} =
             Topology.reconcile_interface_vlans(
               scope,
               source_b,
               incompatible,
               resource.id,
               [%{"name" => "eth0", "vlan_mode" => "access"}],
               true
             )

    assert is_nil(Topology.get_current_interface_vlan_mode(scope, interface.id))

    {:ok, view, _html} = live(conn, ~p"/network/vlans?#{[interface_id: interface.id]}")

    # The membership stays visible and the mode reads as unavailable rather than absent
    # from the collector's report.
    assert has_element?(view, "#current-memberships", "10 · Tagged")
    assert has_element?(view, "#interface-membership-observed-mode", "Unavailable")

    assert has_element?(
             view,
             "#interface-membership-observed-mode > dd p",
             "Membership was observed; no reconciled port mode is available."
           )

    refute has_element?(view, "#interface-membership", "reported no port mode")
  end

  test "keeps a missing mode as not recorded when no membership evidence exists", %{
    conn: conn,
    scope: scope
  } do
    {:ok, resource} =
      Inventory.create_resource(scope, %{
        kind: "server",
        name: "no-evidence-server",
        lifecycle_state: "active"
      })

    {:ok, interface} = Inventory.create_interface(scope, resource.id, %{name: "eth0"})

    {:ok, view, _html} = live(conn, ~p"/network/vlans?#{[interface_id: interface.id]}")

    assert has_element?(view, "#interface-membership-desired-mode", "Not recorded")
    assert has_element?(view, "#interface-membership-observed-mode", "Not recorded")
    refute has_element?(view, "#interface-membership", "no reconciled port mode")
  end

  test "managers create a VLAN and members only read it", %{
    conn: conn,
    organization: organization,
    scope: scope
  } do
    {:ok, group} = create_group(scope, "authoring", [{1, 100}])

    {:ok, view, _html} = live(conn, ~p"/network/vlans")

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

    {:ok, member_view, _html} = live(member_conn, ~p"/network/vlans")

    assert has_element?(member_view, "#vlan-#{vlan.id}", "Management")
    refute has_element?(member_view, "#vlan-form")
  end

  test "rejects a VID outside the selected namespace", %{conn: conn, scope: scope} do
    {:ok, group} = create_group(scope, "bounded", [{1, 100}])

    {:ok, view, _html} = live(conn, ~p"/network/vlans")

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

    assert has_element?(view, "#flash-error", "outside the selected group's ranges")
    assert Topology.list_vlans(scope, group.id) == []
  end

  test "lists linked prefixes read-only and opens a VLAN's detail", %{
    organization: organization,
    scope: scope
  } do
    {:ok, group} = create_group(scope, "prefix-member", [{1, 100}])
    {:ok, vlan} = create_vlan(scope, group, 10, "Management")
    prefix = create_prefix(scope, "prefix-member-server", "192.0.2.0/24")
    {:ok, _relationship} = Topology.attach_prefix_vlan(scope, prefix.id, vlan.id)

    member = user_fixture()
    organization_membership_fixture(member, organization, %{role: "member"})

    member_conn =
      build_conn()
      |> log_in_user(member)
      |> put_session(:current_organization_id, organization.id)

    {:ok, member_view, _html} = live(member_conn, ~p"/network/vlans")

    assert has_element?(member_view, "#vlan-#{vlan.id}-prefixes", "192.0.2.0/24")
    refute has_element?(member_view, "#vlan-#{vlan.id}-prefixes button")

    assert {:error, {:live_redirect, %{to: path}}} =
             member_view |> element("#vlan-#{vlan.id} a") |> render_click()

    assert path == "/network/vlans/#{vlan.id}"
  end

  test "keeps another organization's prefixes and links invisible", %{
    conn: conn,
    scope: scope
  } do
    {:ok, group} = create_group(scope, "prefix-tenant", [{1, 100}])
    {:ok, vlan} = create_vlan(scope, group, 10, "Local")
    prefix = create_prefix(scope, "prefix-tenant-server", "192.0.2.0/24")
    {:ok, _relationship} = Topology.attach_prefix_vlan(scope, prefix.id, vlan.id)

    foreign_user = user_fixture()
    foreign_organization = organization_fixture()
    organization_membership_fixture(foreign_user, foreign_organization, %{role: "admin"})
    foreign_scope = Accounts.scope_for_user(foreign_user, foreign_organization.id)
    foreign_prefix = create_prefix(foreign_scope, "foreign-prefix-server", "198.51.100.0/24")
    {:ok, foreign_group} = create_group(foreign_scope, "foreign-prefix-group", [{1, 100}])
    {:ok, foreign_vlan} = create_vlan(foreign_scope, foreign_group, 10, "Foreign")

    {:ok, _relationship} =
      Topology.attach_prefix_vlan(foreign_scope, foreign_prefix.id, foreign_vlan.id)

    {:ok, view, _html} = live(conn, ~p"/network/vlans")

    assert has_element?(view, "#vlan-#{vlan.id}-prefixes", "192.0.2.0/24")
    refute has_element?(view, "#vlan-#{foreign_vlan.id}-prefixes")
    refute has_element?(view, "[data-prefix-cidr='198.51.100.0/24']")
  end

  test "shows each group's ID-range usage and filters by it", %{conn: conn, scope: scope} do
    {:ok, group} = create_group(scope, "usage", [{1, 99}, {200, 299}])
    {:ok, other} = create_group(scope, "usage-other", [{1, 100}])
    {:ok, low} = create_vlan(scope, group, 10, "Low")
    {:ok, _high} = create_vlan(scope, group, 250, "High")
    {:ok, elsewhere} = create_vlan(scope, other, 10, "Elsewhere")

    {:ok, view, _html} = live(conn, ~p"/network/vlans")

    assert has_element?(view, "#vlan-group-#{group.id}", "2 of 199 IDs")
    assert has_element?(view, "#vlan-group-#{group.id}", "1–99, 200–299")
    assert has_element?(view, "#vlan-group-#{group.id}-strip [data-range='1-99'][data-used='1']")

    assert has_element?(
             view,
             "#vlan-group-#{group.id}-strip [data-range='200-299'][data-used='1']"
           )

    view |> element("#vlan-group-#{group.id} a") |> render_click()
    assert_patch(view, ~p"/network/vlans?#{[group_id: group.id]}")

    assert has_element?(view, "#vlan-#{low.id}")
    refute has_element?(view, "#vlan-#{elsewhere.id}")
  end

  test "counts planned and observed members per VLAN", %{conn: conn, scope: scope} do
    group = vlan_group_fixture(scope, "counts")
    users = vlan_fixture(scope, group, 10, "users")
    {leaf, ports} = device_fixture(scope, "switch", "counts-leaf", ~w(swp1 swp2))
    desire_vlans(scope, ports["swp1"], "access", users)
    desire_vlans(scope, ports["swp2"], "access", users)
    report_vlans(scope, leaf, group, %{"swp1" => {"access", [{10, "untagged"}]}})

    {:ok, view, _html} = live(conn, ~p"/network/vlans")

    assert has_element?(view, "#vlan-#{users.id}-planned", "2")
    assert has_element?(view, "#vlan-#{users.id}-observed", "1")
  end

  test "requires authentication" do
    assert {:error, {:redirect, %{to: path}}} = live(build_conn(), ~p"/network/vlans")
    assert path =~ "/users/log-in"
  end

  test "keeps another organization's VLANs and namespaces invisible", %{conn: conn, scope: scope} do
    {:ok, group} = create_group(scope, "local-vlans", [{1, 10}])
    {:ok, vlan} = create_vlan(scope, group, 5, "Local")

    foreign_user = user_fixture()
    foreign_organization = organization_fixture()
    organization_membership_fixture(foreign_user, foreign_organization, %{role: "admin"})
    foreign_scope = Accounts.scope_for_user(foreign_user, foreign_organization.id)
    {:ok, foreign_group} = create_group(foreign_scope, "foreign-vlans", [{1, 10}])
    {:ok, foreign_vlan} = create_vlan(foreign_scope, foreign_group, 5, "Foreign")

    {:ok, view, _html} = live(conn, ~p"/network/vlans")

    assert has_element?(view, "#vlan-#{vlan.id}")
    refute has_element?(view, "#vlan-#{foreign_vlan.id}")
    assert has_element?(view, "#vlan-form option[value='#{group.id}']")
    refute has_element?(view, "#vlan-form option[value='#{foreign_group.id}']")
  end

  test "tracks VLAN form values and resets them after success", %{conn: conn, scope: scope} do
    {:ok, group} = create_group(scope, "form-tracking", [{1, 100}])
    {:ok, view, _html} = live(conn, ~p"/network/vlans")

    values = %{
      vlan_group_id: group.id,
      vid: "10",
      name: "Management",
      status: "active",
      role: "management",
      description: "Core"
    }

    view |> form("#vlan-form", vlan: values) |> render_change()

    assert has_element?(view, "#vlan-form input[name='vlan[name]'][value='Management']")

    # A failed submission keeps the entered values for correction.
    view
    |> form("#vlan-form", vlan: %{values | vid: "250"})
    |> render_submit()

    assert has_element?(view, "#flash-error", "outside the selected group's ranges")
    assert has_element?(view, "#vlan-form input[name='vlan[name]'][value='Management']")

    # A successful submission resets the form to its defaults.
    view |> form("#vlan-form", vlan: values) |> render_submit()

    assert has_element?(view, "#flash-info", "VLAN 10 created")
    assert has_element?(view, "#vlan-form input[name='vlan[name]'][value='']")
    assert has_element?(view, "#vlan-form input[name='vlan[vid]'][value='']")

    assert [vlan] = Topology.list_vlans(scope, group.id)
    assert vlan.vid == 10
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

  defp create_prefix(scope, resource_name, cidr) do
    {:ok, resource} =
      Inventory.create_resource(scope, %{
        kind: "prefix",
        name: resource_name,
        lifecycle_state: "active"
      })

    {:ok, prefix} = Inventory.create_prefix(scope, resource.id, %{prefix: cidr})
    prefix
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
