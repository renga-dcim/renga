defmodule RengaWeb.ResourceLiveTest do
  use RengaWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Renga.AccountsFixtures
  import Renga.InventoryFixtures

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
    resource: resource
  } do
    {:ok, view, _html} = live(conn, ~p"/inventory/#{resource.id}")

    assert has_element?(
             view,
             "#identifier-claims [data-claim-kind='serial_number']",
             "1 observation"
           )
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

    {:ok, view, _html} = live(conn, ~p"/inventory/#{resource.id}")

    assert has_element?(view, "#resource-detail")

    assert has_element?(
             view,
             "#resource-hardware-link[href='/inventory/#{resource.id}/hardware']"
           )

    assert has_element?(view, "#desired-state", "power")
    assert has_element?(view, "#canonical-projection", "compute-01.example.net")
    assert has_element?(view, "#canonical-identifiers", "SN-123")
    assert has_element?(view, "#identifier-claims", "rack-agent")

    assert has_element?(
             view,
             "#identifier-claims [data-claim-kind='serial_number']",
             "100% 2026-08-07 10:00 UTC 2026-08-07 10:01 UTC 2 observations"
           )

    assert has_element?(view, "#resource-interfaces", "192.0.2.10/24")
    assert has_element?(view, "#resource-conditions", "InventoryCurrent")
    assert has_element?(view, "#change-events", "discovered")
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

    {:ok, view, _html} = live(conn, ~p"/inventory/#{resource.id}")

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
    {:ok, view, _html} = live(conn, ~p"/inventory/#{resource.id}")

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
             "#interface-#{interface.id}-neighbors[href='/network/topology?interface_id=#{interface.id}#observed-neighbors']"
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

    refute has_element?(view, "#resource-hardware-link")
  end
end
