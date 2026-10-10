defmodule RengaWeb.ResourceLiveTest do
  use RengaWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Renga.AccountsFixtures
  import Renga.FindingsFixtures
  import Renga.InventoryFixtures

  alias Renga.Findings
  alias Renga.Inventory

  setup %{conn: conn} do
    user = user_fixture()
    organization = organization_fixture()
    membership = organization_membership_fixture(user, organization, %{role: "admin"})
    scope = Renga.Accounts.scope_for_user(user, organization.id)

    conn =
      conn
      |> log_in_user(user)
      |> put_session(:current_organization_id, organization.id)

    {:ok, source} = Inventory.create_source(scope, %{kind: "host_agent", name: "rack-agent"})

    {:ok, resource} =
      Inventory.create_resource(scope, %{
        kind: "server",
        name: "compute-01",
        lifecycle_state: "active",
        spec: %{"power" => "on"}
      })

    {:ok, _host} =
      Inventory.create_host(scope, resource.id, %{
        hostname: "compute-01",
        fqdn: "compute-01.example.net",
        vendor: "Acme",
        model: "DenseBox"
      })

    {:ok, _condition} =
      Inventory.put_resource_condition(scope, resource.id, %{
        type: "InventoryCurrent",
        status: "false",
        reason: "ObservationExpired"
      })

    {:ok, identifier} =
      Inventory.create_resource_identifier(scope, resource.id, %{
        kind: "serial_number",
        value: "SN-123"
      })

    {:ok, observation} =
      Inventory.create_observation(scope, source.id, %{
        observation_id: "resource-live-report",
        observed_at: ~U[2026-08-07 10:00:00.000000Z],
        payload: %{"hostname" => "compute-01"}
      })

    {:ok, _claim} =
      Inventory.create_resource_identifier_claim(scope, source.id, observation.id, %{
        resource_id: resource.id,
        resource_identifier_id: identifier.id,
        kind: "serial_number",
        value: "SN-123",
        confidence: 100
      })

    {:ok, interface} =
      Inventory.create_interface(scope, resource.id, %{
        name: "eth0",
        mac_address: "02:00:00:00:00:01",
        status: "up"
      })

    {:ok, _address} =
      Inventory.create_address(scope, interface.id, %{
        kind: "ipv4",
        address: "192.0.2.10/24"
      })

    {:ok, _event} =
      Inventory.create_change_event(scope, %{
        kind: "discovered",
        resource_id: resource.id,
        source_id: source.id,
        occurred_at: ~U[2026-08-07 10:00:00.000000Z]
      })

    %{
      conn: conn,
      scope: scope,
      resource: resource,
      interface: interface,
      membership: membership,
      organization: organization
    }
  end

  test "IP-address lifecycle controls stay with IPAM, including bulk selections", %{
    conn: conn,
    scope: scope,
    interface: interface
  } do
    [observed] = Inventory.list_addresses(scope, interface.id)
    {:ok, managed} = Renga.IPAM.adopt_address(scope, observed.id)
    {:ok, view, _} = live(conn, ~p"/inventory/#{managed.resource_id}")
    refute has_element?(view, "#resource-lifecycle-form")
    refute has_element?(view, "#resource-lifecycle-request-toggle")
    assert has_element?(view, "#resource-lifecycle-help", "Managed by IPAM")

    {:ok, view, _} = live(conn, ~p"/inventory?#{[sel: managed.resource_id]}")
    refute has_element?(view, "#bulk-lifecycle-menu")
    assert has_element?(view, "#bulk-lifecycle-ipam")
    render_hook(view, "bulk_lifecycle", %{"state" => "retired"})
    assert Inventory.get_resource!(scope, managed.resource_id).lifecycle_state == "active"
  end

  test "organization managers update lifecycle from the full resource detail", %{
    conn: conn,
    scope: scope,
    resource: resource
  } do
    {:ok, view, _html} = live(conn, ~p"/inventory/#{resource.id}")

    view
    |> form("#resource-lifecycle-form", lifecycle: %{lifecycle_state: "retired"})
    |> render_submit()

    assert Inventory.get_resource!(scope, resource.id).lifecycle_state == "retired"

    assert has_element?(
             view,
             "#resource-lifecycle-form select option[value='retired'][selected]"
           )

    render_hook(view, "update_lifecycle", %{
      "lifecycle" => %{"lifecycle_state" => "missing"}
    })

    assert Inventory.get_resource!(scope, resource.id).lifecycle_state == "retired"
    assert has_element?(view, "#flash-error", "valid lifecycle")
  end

  test "full lifecycle edit reloads after a concurrent resource change", %{
    conn: conn,
    scope: scope,
    resource: resource
  } do
    {:ok, view, _html} = live(conn, ~p"/inventory/#{resource.id}")

    assert {:ok, _resource} =
             Inventory.update_resource(scope, resource, %{lifecycle_state: "inactive"})

    view
    |> form("#resource-lifecycle-form", lifecycle: %{lifecycle_state: "retired"})
    |> render_submit()

    assert Inventory.get_resource!(scope, resource.id).lifecycle_state == "inactive"
    assert has_element?(view, "#flash-error", "changed elsewhere")

    assert has_element?(
             view,
             "#resource-lifecycle-form select option[value='inactive'][selected]"
           )
  end

  test "viewers cannot see or forge lifecycle changes", %{
    organization: organization,
    resource: resource,
    scope: scope
  } do
    viewer = user_fixture()
    organization_membership_fixture(viewer, organization, %{role: "viewer"})

    conn =
      build_conn()
      |> log_in_user(viewer)
      |> put_session(:current_organization_id, organization.id)

    {:ok, view, _html} = live(conn, ~p"/inventory/#{resource.id}")
    refute has_element?(view, "#resource-lifecycle-form")
    assert has_element?(view, "#resource-lifecycle-help", "does not control the device")

    render_hook(view, "update_lifecycle", %{
      "lifecycle" => %{"lifecycle_state" => "retired"}
    })

    assert Inventory.get_resource!(scope, resource.id).lifecycle_state == "active"
    assert has_element?(view, "#flash-error", "not allowed")
  end

  test "a stale admin scope cannot change lifecycle after role downgrade", %{
    conn: conn,
    scope: scope,
    resource: resource,
    membership: membership
  } do
    {:ok, view, _html} = live(conn, ~p"/inventory/#{resource.id}")

    {:ok, _membership} =
      Renga.Accounts.update_organization_membership(membership, %{role: "viewer"})

    view
    |> form("#resource-lifecycle-form", lifecycle: %{lifecycle_state: "retired"})
    |> render_submit()

    assert Inventory.get_resource!(scope, resource.id).lifecycle_state == "active"
    assert has_element?(view, "#flash-error", "not allowed")
  end

  test "uses singular evidence count for one identifier claim", %{
    conn: conn,
    scope: scope,
    resource: resource
  } do
    [claim] = Inventory.list_resource_identifier_claims(scope, resource.id)
    {:ok, view, _html} = live(conn, ~p"/inventory/#{resource.id}/sources")

    assert has_element?(view, "#claim-#{claim.id}", "1 observation")
  end

  test "shows desired state, canonical projections, provenance, and audit history", %{
    conn: conn,
    scope: scope,
    resource: resource
  } do
    [claim] = Inventory.list_resource_identifier_claims(scope, resource.id)

    {:ok, second_observation} =
      Inventory.create_observation(scope, claim.source_id, %{
        observation_id: "resource-live-report-2",
        observed_at: ~U[2026-08-07 10:01:00.000000Z],
        payload: %{"hostname" => "compute-01"}
      })

    {:ok, _claim} =
      Inventory.create_resource_identifier_claim(scope, claim.source_id, second_observation.id, %{
        resource_id: resource.id,
        resource_identifier_id: claim.resource_identifier_id,
        kind: claim.kind,
        value: claim.value,
        confidence: claim.confidence
      })

    operational_resource = Inventory.get_operational_resource!(scope, resource.id)

    assert [%{observation_count: 2}] =
             Enum.filter(operational_resource.identifier_claims, &(&1.kind == "serial_number"))

    [latest_claim] =
      Enum.filter(operational_resource.identifier_claims, &(&1.kind == "serial_number"))

    {:ok, view, _html} = live(conn, ~p"/inventory/#{resource.id}")

    # Overview: status, intent, conditions, and the properties aside.
    assert has_element?(view, "#resource-detail h1", "compute-01")
    assert has_element?(view, "#resource-status [data-signal='lifecycle']", "Active")
    assert has_element?(view, "#desired-state", "power")
    assert has_element?(view, "#resource-conditions", "InventoryCurrent")
    assert has_element?(view, "#resource-properties", "compute-01.example.net")
    assert has_element?(view, "#resource-properties", "rack-agent")

    for {tab, path} <- [
          {"Hardware", "/inventory/#{resource.id}/hardware"},
          {"Network", "/inventory/#{resource.id}/network"},
          {"Sources", "/inventory/#{resource.id}/sources"},
          {"Activity", "/inventory/#{resource.id}/activity"}
        ] do
      assert has_element?(view, "#resource-detail-tabs a[href='#{path}']", tab)
    end

    assert has_element?(view, "#resource-detail-tabs a[aria-current='page']", "Overview")

    # Tabs within the page patch rather than reload.
    view |> element("#resource-detail-tabs a", "Sources") |> render_click()
    assert_patch(view, ~p"/inventory/#{resource.id}/sources")
    assert has_element?(view, "#canonical-identifiers", "SN-123")
    assert has_element?(view, "#claims", "rack-agent")

    assert has_element?(
             view,
             "#claim-#{latest_claim.id}",
             "100% 2026-08-07 10:00 UTC 2026-08-07 10:01 UTC 2 observations"
           )

    view |> element("#resource-detail-tabs a", "Network") |> render_click()
    assert has_element?(view, "#resource-interfaces", "192.0.2.10/24")

    view |> element("#resource-detail-tabs a", "Activity") |> render_click()
    assert has_element?(view, "#change-events", "Discovered")
  end

  test "renders host prefixes for inet addresses without a netmask", %{
    conn: conn,
    scope: scope,
    resource: resource,
    interface: interface
  } do
    {:ok, _ipv4} =
      Inventory.create_address(scope, interface.id, %{
        kind: "ipv4",
        address: %Postgrex.INET{address: {198, 51, 100, 7}, netmask: nil}
      })

    {:ok, _ipv6} =
      Inventory.create_address(scope, interface.id, %{
        kind: "ipv6",
        address: %Postgrex.INET{address: {0x2001, 0xDB8, 0, 0, 0, 0, 0, 7}, netmask: nil}
      })

    {:ok, view, _html} = live(conn, ~p"/inventory/#{resource.id}/network")

    assert has_element?(
             view,
             "#resource-interfaces [data-address-kind='ipv4']",
             "198.51.100.7/32"
           )

    assert has_element?(
             view,
             "#resource-interfaces [data-address-kind='ipv6']",
             "2001:db8::7/128"
           )
  end

  test "links each interface to its Layer 2 concepts without conflating them", %{
    conn: conn,
    resource: resource,
    interface: interface
  } do
    {:ok, view, _html} = live(conn, ~p"/inventory/#{resource.id}/network")

    assert has_element?(
             view,
             "#interface-#{interface.id}-memberships[href='/network/vlans?interface_id=#{interface.id}#interface-membership']"
           )

    assert has_element?(
             view,
             "#interface-#{interface.id}-relationships[href='/network/topology?interface_id=#{interface.id}#logical-relationships']"
           )

    assert has_element?(
             view,
             "#interface-#{interface.id}-neighbors[href='/network/topology?interface_id=#{interface.id}#topology-links']"
           )

    assert has_element?(
             view,
             "#interface-#{interface.id}-cables[href='/network/cables?interface_id=#{interface.id}#current-cables']"
           )

    # All four links share one group so the last one cannot wrap alone under the label.
    for suffix <- ~w(memberships relationships neighbors cables) do
      assert has_element?(
               view,
               "#interface-#{interface.id}-layer2-links > a#interface-#{interface.id}-#{suffix}"
             )
    end
  end

  test "resource detail enforces organization scope", %{conn: conn} do
    other_organization = organization_fixture(%{name: "Other Operations"})
    other_scope = Renga.Accounts.scope_for(other_organization)

    {:ok, foreign_resource} =
      Inventory.create_resource(other_scope, %{kind: "server", name: "secret"})

    assert_raise Ecto.NoResultsError, fn ->
      live(conn, ~p"/inventory/#{foreign_resource.id}")
    end
  end

  test "unsupported resource detail does not link to hardware assignment", %{
    conn: conn,
    scope: scope
  } do
    {:ok, vm} = Inventory.create_resource(scope, %{kind: "vm", name: "detail-vm"})

    {:ok, view, _html} = live(conn, ~p"/inventory/#{vm.id}")

    # Hardware applies to physical devices only; the tab is absent and the
    # command menu explains why instead.
    assert has_element?(view, "#resource-detail-tabs a", "Network")
    refute has_element?(view, "#resource-detail-tabs a", "Hardware")
    assert has_element?(view, "#command-open-hardware[aria-disabled='true']")
  end

  test "shows open hardware findings as drift in the list, header, and Hardware tab", %{
    conn: conn,
    scope: scope,
    resource: resource
  } do
    for status <- ["open", "open", "resolved"] do
      %Renga.Catalog.ComponentFinding{
        organization_id: scope.organization_id,
        resource_id: resource.id
      }
      |> Renga.Catalog.ComponentFinding.changeset(%{
        kind: "component_drift",
        resolution_key: "drift:#{System.unique_integer([:positive])}",
        status: status,
        message: "Component drift",
        resolved_at: if(status == "resolved", do: ~U[2026-08-20 13:00:00.000000Z]),
        last_observed_at: ~U[2026-08-20 12:00:00.000000Z]
      })
      |> Renga.Repo.insert!()
    end

    {:ok, view, _html} = live(conn, ~p"/inventory/#{resource.id}")

    assert has_element?(view, "#resource-status [data-signal='drift']", "2 drift findings")

    assert has_element?(
             view,
             "#resource-drift[href='/inventory/#{resource.id}/hardware']",
             "2 open"
           )

    assert has_element?(view, "#resource-detail-tabs a[href$='/hardware']", "2")

    {:ok, list, _html} = live(conn, ~p"/inventory")

    assert has_element?(
             list,
             "#resources-#{resource.id} [data-signal='drift']",
             "2 drift findings"
           )
  end

  test "the resource page shows accepted exceptions and links to its findings", %{
    conn: conn,
    scope: scope,
    resource: resource
  } do
    component_finding_fixture(resource, "component_drift")
    component_finding_fixture(resource, "missing_expected_component", key: "x")
    {[finding | _rest], 2} = Findings.list_findings(scope)

    {:ok, _workflow} =
      Findings.accept_exception(scope, finding, %{"exception_reason" => "Spare pulled for RMA"})

    {:ok, view, _html} = live(conn, ~p"/inventory/#{resource}")

    assert has_element?(view, "#resource-exceptions", "Spare pulled for RMA")
    assert has_element?(view, "#resource-exceptions", "Accepted by #{scope.user.email}")

    assert has_element?(
             view,
             "#resource-findings[href='/inbox?resource=#{resource.id}']",
             "1 open finding"
           )
  end

  test "updates when the resource changes elsewhere", %{
    conn: conn,
    scope: scope,
    resource: resource
  } do
    {:ok, view, _html} = live(conn, ~p"/inventory/#{resource.id}")
    assert has_element?(view, "#resource-status [data-signal='lifecycle']", "Active")

    {:ok, _resource} = Inventory.update_resource_lifecycle(scope, resource, "retired")

    assert Enum.any?(1..40, fn _attempt ->
             has_element?(view, "#resource-status [data-signal='lifecycle']", "Retired") or
               (Process.sleep(25) && false)
           end)
  end
end
