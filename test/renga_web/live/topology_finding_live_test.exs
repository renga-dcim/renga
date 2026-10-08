defmodule RengaWeb.TopologyFindingLiveTest do
  use RengaWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Renga.AccountsFixtures
  import Renga.InventoryFixtures

  alias Renga.Accounts
  alias Renga.Inventory
  alias Renga.Repo
  alias Renga.Topology.TopologyFinding

  setup %{conn: conn} do
    user = user_fixture()
    organization = organization_fixture()
    organization_membership_fixture(user, organization, %{role: "admin"})
    scope = Accounts.scope_for_user(user, organization.id)

    conn =
      conn
      |> log_in_user(user)
      |> put_session(:current_organization_id, organization.id)

    {:ok, resource} =
      Inventory.create_resource(scope, %{
        kind: "server",
        name: "finding-ui-server",
        lifecycle_state: "active"
      })

    {:ok, interface} = Inventory.create_interface(scope, resource.id, %{name: "eth0"})

    %{
      conn: conn,
      organization: organization,
      resource: resource,
      interface: interface,
      scope: scope
    }
  end

  test "lists open findings and filters by state and kind", %{
    conn: conn,
    interface: interface,
    scope: scope
  } do
    open = finding_fixture(scope, interface, "cable_plan_drift", "open")
    resolved = finding_fixture(scope, interface, "missing_vlan", "resolved")

    {:ok, view, _html} = live(conn, ~p"/inbox/topology")

    assert has_element?(view, "#topology-findings")

    assert has_element?(
             view,
             "#topology-finding-#{open.id}[data-finding-kind='cable_plan_drift']"
           )

    assert has_element?(view, "#topology-finding-#{open.id}", "cable plan drift")
    refute has_element?(view, "#topology-finding-#{resolved.id}")

    view
    |> form("#topology-finding-filters", filters: %{status: "resolved", kind: "all"})
    |> render_change()

    refute has_element?(view, "#topology-finding-#{open.id}")
    assert has_element?(view, "#topology-finding-#{resolved.id}", "missing vlan")

    view
    |> form("#topology-finding-filters", filters: %{status: "open", kind: "cable_plan_drift"})
    |> render_change()

    assert has_element?(view, "#topology-finding-#{open.id}")
    refute has_element?(view, "#topology-finding-#{resolved.id}")
  end

  test "shows finding details and links the interface to its resource", %{
    conn: conn,
    resource: resource,
    interface: interface,
    scope: scope
  } do
    finding = finding_fixture(scope, interface, "cable_neighbor_mismatch", "open")

    {:ok, view, _html} = live(conn, ~p"/inbox/topology")

    assert has_element?(
             view,
             "#topology-finding-#{finding.id} a[href='/inventory/#{resource.id}']"
           )

    assert has_element?(view, "#topology-finding-#{finding.id}", "eth0")
    assert has_element?(view, "#topology-finding-#{finding.id}", "remote interface ids")
  end

  test "keeps another organization's findings invisible", %{
    conn: conn,
    interface: interface,
    scope: scope
  } do
    local = finding_fixture(scope, interface, "cable_plan_drift", "open")

    foreign_user = user_fixture()
    foreign_organization = organization_fixture()
    organization_membership_fixture(foreign_user, foreign_organization, %{role: "admin"})
    foreign_scope = Accounts.scope_for_user(foreign_user, foreign_organization.id)

    {:ok, foreign_resource} =
      Inventory.create_resource(foreign_scope, %{
        kind: "server",
        name: "foreign-finding-server",
        lifecycle_state: "active"
      })

    {:ok, foreign_interface} =
      Inventory.create_interface(foreign_scope, foreign_resource.id, %{name: "eth0"})

    foreign = finding_fixture(foreign_scope, foreign_interface, "cable_plan_drift", "open")

    {:ok, view, _html} = live(conn, ~p"/inbox/topology")

    assert has_element?(view, "#topology-finding-#{local.id}")
    refute has_element?(view, "#topology-finding-#{foreign.id}")
  end

  test "members read findings", %{
    organization: organization,
    interface: interface,
    scope: scope
  } do
    finding = finding_fixture(scope, interface, "cable_endpoint_conflict", "open")

    member = user_fixture()
    organization_membership_fixture(member, organization, %{role: "viewer"})

    member_conn =
      build_conn()
      |> log_in_user(member)
      |> put_session(:current_organization_id, organization.id)

    {:ok, view, _html} = live(member_conn, ~p"/inbox/topology")

    assert has_element?(view, "#topology-finding-#{finding.id}")
    refute has_element?(view, "#topology-findings-list form")
    refute has_element?(view, "#topology-findings-list [phx-click]")
  end

  test "requires authentication" do
    assert {:error, {:redirect, %{to: path}}} = live(build_conn(), ~p"/inbox/topology")
    assert path =~ "/users/log-in"
  end

  test "filters findings by interface and keeps the restriction across patches", %{
    conn: conn,
    resource: resource,
    interface: interface,
    scope: scope
  } do
    {:ok, other_interface} = Inventory.create_interface(scope, resource.id, %{name: "eth1"})
    first = finding_fixture(scope, interface, "cable_plan_drift", "open")
    second = finding_fixture(scope, other_interface, "missing_vlan", "open")

    {:ok, view, _html} =
      live(conn, ~p"/inbox/topology?#{[interface_id: interface.id]}")

    assert has_element?(view, "#topology-finding-#{first.id}")
    refute has_element?(view, "#topology-finding-#{second.id}")

    # Changing state and kind keeps the interface restriction.
    view
    |> form("#topology-finding-filters", filters: %{status: "open", kind: "missing_vlan"})
    |> render_change()

    assert_patch(view)

    refute has_element?(view, "#topology-finding-#{first.id}")
    refute has_element?(view, "#topology-finding-#{second.id}")

    # A foreign interface id cannot expose foreign findings.
    foreign_user = user_fixture()
    foreign_organization = organization_fixture()
    organization_membership_fixture(foreign_user, foreign_organization, %{role: "admin"})
    foreign_scope = Accounts.scope_for_user(foreign_user, foreign_organization.id)

    {:ok, foreign_resource} =
      Inventory.create_resource(foreign_scope, %{
        kind: "server",
        name: "foreign-filter-server",
        lifecycle_state: "active"
      })

    {:ok, foreign_interface} =
      Inventory.create_interface(foreign_scope, foreign_resource.id, %{name: "eth0"})

    foreign = finding_fixture(foreign_scope, foreign_interface, "cable_plan_drift", "open")

    {:ok, foreign_view, _html} =
      live(conn, ~p"/inbox/topology?#{[interface_id: foreign_interface.id]}")

    refute has_element?(foreign_view, "#topology-finding-#{foreign.id}")
    refute has_element?(foreign_view, "#topology-finding-#{first.id}")
  end

  test "treats kind=all and blank kinds as unfiltered", %{
    conn: conn,
    interface: interface,
    scope: scope
  } do
    drift = finding_fixture(scope, interface, "cable_plan_drift", "open")
    missing = finding_fixture(scope, interface, "missing_vlan", "open")

    for params <- [%{}, %{kind: ""}, %{kind: "all"}] do
      {:ok, view, _html} = live(conn, ~p"/inbox/topology?#{params}")

      assert has_element?(view, "#topology-finding-#{drift.id}")
      assert has_element?(view, "#topology-finding-#{missing.id}")
    end

    {:ok, view, _html} =
      live(conn, ~p"/inbox/topology?#{[kind: "missing_vlan"]}")

    refute has_element?(view, "#topology-finding-#{drift.id}")
    assert has_element?(view, "#topology-finding-#{missing.id}")

    # Selecting All kinds again restores the other rows.
    view
    |> form("#topology-finding-filters", filters: %{status: "open", kind: "all"})
    |> render_change()

    assert has_element?(view, "#topology-finding-#{drift.id}")
    assert has_element?(view, "#topology-finding-#{missing.id}")
  end

  defp finding_fixture(scope, interface, kind, status) do
    resolved_at = if status == "resolved", do: ~U[2026-09-20 13:00:00.000000Z]

    %TopologyFinding{
      organization_id: scope.organization_id,
      interface_id: interface.id
    }
    |> TopologyFinding.changeset(%{
      kind: kind,
      resolution_key: "#{kind}:#{System.unique_integer([:positive])}",
      status: status,
      message: kind |> String.replace("_", " ") |> String.capitalize(),
      details: %{"remote_interface_ids" => ["00000000-0000-0000-0000-000000000001"]},
      resolved_at: resolved_at,
      last_observed_at: ~U[2026-09-20 12:00:00.000000Z]
    })
    |> Repo.insert!()
  end
end
