defmodule Renga.InventoryTest do
  use Renga.DataCase, async: true

  alias Renga.Accounts
  alias Renga.Inventory
  alias Renga.Inventory.Address
  alias Renga.Inventory.ChangeEvent
  alias Renga.Inventory.Host
  alias Renga.Inventory.Interface
  alias Renga.Inventory.InterfaceRelationship
  alias Renga.Inventory.Observation
  alias Renga.Inventory.Resource
  alias Renga.Inventory.ResourceCondition
  alias Renga.Inventory.ResourceIdentifier
  alias Renga.Inventory.ResourceOverride
  alias Renga.Inventory.ResourceRevision
  alias Renga.Inventory.Source
  alias Renga.Inventory.SyncRun

  defp unique_slug(prefix), do: "#{prefix}-#{System.unique_integer([:positive])}"

  defp scoped_organizations do
    {:ok, organization} =
      Accounts.create_organization(%{
        name: "Acme Operations",
        slug: unique_slug("acme-ops")
      })

    {:ok, other_organization} =
      Accounts.create_organization(%{
        name: "Beta Operations",
        slug: unique_slug("beta-ops")
      })

    %{
      scope: Accounts.scope_for(organization),
      other_scope: Accounts.scope_for(other_organization)
    }
  end

  describe "sources" do
    setup do
      scoped_organizations()
    end

    test "create_source/2 creates an organization-scoped source", %{scope: scope} do
      assert {:ok, %Source{} = source} =
               Inventory.create_source(scope, %{
                 kind: "host_agent",
                 name: "iad-1-host-agent",
                 capabilities: ["host.inventory"],
                 metadata: %{"interval_seconds" => 60}
               })

      assert {:ok, _uuid} = Ecto.UUID.cast(source.id)
      assert source.organization_id == scope.organization_id
      assert source.status == "active"
      assert source.capabilities == ["host.inventory"]
      assert source.metadata == %{"interval_seconds" => 60}
    end

    test "list_sources/1 is scoped by organization", %{scope: scope, other_scope: other_scope} do
      {:ok, source} =
        Inventory.create_source(scope, %{
          kind: "host_agent",
          name: "iad-1-host-agent"
        })

      {:ok, _other_source} =
        Inventory.create_source(other_scope, %{
          kind: "host_agent",
          name: "iad-1-host-agent"
        })

      assert Inventory.list_sources(scope) == [source]
    end

    test "get_source!/2 enforces organization scope", %{scope: scope, other_scope: other_scope} do
      {:ok, source} =
        Inventory.create_source(scope, %{
          kind: "host_agent",
          name: "iad-1-host-agent"
        })

      assert Inventory.get_source!(scope, source.id).id == source.id

      assert_raise Ecto.NoResultsError, fn ->
        Inventory.get_source!(other_scope, source.id)
      end
    end

    test "source names are unique per organization", %{scope: scope, other_scope: other_scope} do
      attrs = %{kind: "host_agent", name: "iad-1-host-agent"}

      assert {:ok, _source} = Inventory.create_source(scope, attrs)
      assert {:ok, _source} = Inventory.create_source(other_scope, attrs)

      assert {:error, changeset} = Inventory.create_source(scope, attrs)
      assert %{organization_id: ["has already been taken"]} = errors_on(changeset)
    end

    test "validates kind and status", %{scope: scope} do
      assert {:error, changeset} =
               Inventory.create_source(scope, %{
                 kind: "unknown",
                 name: "bad-source",
                 status: "missing"
               })

      assert %{
               kind: ["is invalid"],
               status: ["is invalid"]
             } = errors_on(changeset)
    end

    test "validates capabilities", %{scope: scope} do
      assert {:error, changeset} =
               Inventory.create_source(scope, %{
                 kind: "host_agent",
                 name: "bad-source",
                 capabilities: ["host.inventory", "   "]
               })

      assert %{capabilities: ["must contain only non-empty strings"]} = errors_on(changeset)
    end

    test "programmatic organization id is not cast from attrs", %{scope: scope} do
      assert {:ok, source} =
               Inventory.create_source(scope, %{
                 organization_id: Ecto.UUID.generate(),
                 kind: "host_agent",
                 name: "iad-1-host-agent"
               })

      assert source.organization_id == scope.organization_id
    end

    test "create_source_with_token/2 returns plaintext token and stores only a hash", %{
      scope: scope
    } do
      assert {:ok, {%Source{} = source, token}} =
               Inventory.create_source_with_token(scope, %{
                 kind: "host_agent",
                 name: "iad-1-host-agent"
               })

      assert String.starts_with?(token, "renga_src_")
      assert is_binary(source.token_hash)
      refute source.token_hash == token

      assert {:ok, authed_source} = Inventory.authenticate_source_token(token)
      assert authed_source.id == source.id
      assert authed_source.organization_id == scope.organization_id
    end

    test "regular source changes cannot set token_hash", %{scope: scope} do
      assert {:ok, source} =
               Inventory.create_source(scope, %{
                 kind: "host_agent",
                 name: "iad-1-host-agent",
                 token_hash: "caller-controlled"
               })

      assert source.token_hash == nil
    end

    test "rotate_source_token/2 replaces the token hash and invalidates old token", %{
      scope: scope
    } do
      {:ok, {source, old_token}} =
        Inventory.create_source_with_token(scope, %{
          kind: "host_agent",
          name: "iad-1-host-agent"
        })

      assert {:ok, {rotated_source, new_token}} = Inventory.rotate_source_token(scope, source.id)

      assert String.starts_with?(new_token, "renga_src_")
      refute new_token == old_token
      refute rotated_source.token_hash == source.token_hash
      assert rotated_source.status == "active"
      assert Inventory.authenticate_source_token(old_token) == :error
      assert {:ok, authed_source} = Inventory.authenticate_source_token(new_token)
      assert authed_source.id == source.id
    end

    test "rotate_source_token/2 is organization-scoped", %{
      scope: scope,
      other_scope: other_scope
    } do
      {:ok, {source, _token}} =
        Inventory.create_source_with_token(scope, %{
          kind: "host_agent",
          name: "iad-1-host-agent"
        })

      assert_raise Ecto.NoResultsError, fn ->
        Inventory.rotate_source_token(other_scope, source.id)
      end
    end

    test "revoke_source_token/2 removes token auth and marks source revoked", %{scope: scope} do
      {:ok, {source, token}} =
        Inventory.create_source_with_token(scope, %{
          kind: "host_agent",
          name: "iad-1-host-agent"
        })

      assert {:ok, revoked_source} = Inventory.revoke_source_token(scope, source.id)

      assert revoked_source.status == "revoked"
      assert revoked_source.token_hash == nil
      assert Inventory.authenticate_source_token(token) == :error
    end

    test "authenticate_source_token/1 rejects tokens for disabled organizations", %{scope: scope} do
      {:ok, {_source, token}} =
        Inventory.create_source_with_token(scope, %{
          kind: "host_agent",
          name: "iad-1-host-agent"
        })

      organization = Accounts.get_organization!(scope.organization_id)

      assert {:ok, _organization} =
               Accounts.update_organization(organization, %{status: "disabled"})

      assert Inventory.authenticate_source_token(token) == :error
    end

    test "authenticate_source_token/1 rejects malformed tokens" do
      assert Inventory.authenticate_source_token("not-a-source-token") == :error
      assert Inventory.authenticate_source_token(nil) == :error
    end
  end

  describe "resources" do
    setup do
      scoped_organizations()
    end

    test "create_resource/2 creates a versioned organization-scoped envelope", %{scope: scope} do
      assert {:ok, %Resource{} = resource} =
               Inventory.create_resource(scope, %{
                 kind: "server",
                 name: "compute-01",
                 display_name: "Compute 01",
                 lifecycle_state: "active",
                 spec: %{"power" => %{"policy" => "on"}},
                 labels: %{"site" => "iad"}
               })

      assert {:ok, _uuid} = Ecto.UUID.cast(resource.id)
      assert resource.organization_id == scope.organization_id
      assert resource.name == "compute-01"
      assert resource.lifecycle_state == "active"
      assert resource.spec == %{"power" => %{"policy" => "on"}}
      assert resource.generation == 1
      assert resource.resource_version > 0

      assert [%ResourceRevision{} = revision] =
               Inventory.list_resource_revisions(scope, resource.id)

      assert revision.revision == resource.resource_version
      assert revision.action == "created"
    end

    test "list_resources/1 and get_resource!/2 are scoped by organization", %{
      scope: scope,
      other_scope: other_scope
    } do
      {:ok, resource} =
        Inventory.create_resource(scope, %{
          kind: "server",
          name: "compute-01"
        })

      {:ok, _other_resource} =
        Inventory.create_resource(other_scope, %{
          kind: "server",
          name: "compute-01"
        })

      assert Inventory.list_resources(scope) == [resource]
      assert Inventory.get_resource!(scope, resource.id).id == resource.id

      assert_raise Ecto.NoResultsError, fn ->
        Inventory.get_resource!(other_scope, resource.id)
      end
    end

    test "create_resource/2 validates kind and lifecycle state", %{scope: scope} do
      assert {:error, changeset} =
               Inventory.create_resource(scope, %{
                 kind: "unknown-kind",
                 name: "invalid",
                 lifecycle_state: "missing"
               })

      assert %{
               kind: ["is invalid"],
               lifecycle_state: ["is invalid"]
             } = errors_on(changeset)
    end

    test "resource uniqueness constraints are organization-scoped", %{
      scope: scope,
      other_scope: other_scope
    } do
      attrs = %{
        kind: "server",
        name: "compute-01"
      }

      assert {:ok, _resource} = Inventory.create_resource(scope, attrs)
      assert {:ok, _resource} = Inventory.create_resource(other_scope, attrs)

      assert {:error, changeset} = Inventory.create_resource(scope, attrs)
      assert %{organization_id: ["has already been taken"]} = errors_on(changeset)
    end

    test "programmatic organization id is not cast from attrs", %{scope: scope} do
      assert {:ok, resource} =
               Inventory.create_resource(scope, %{
                 organization_id: Ecto.UUID.generate(),
                 kind: "server",
                 name: "compute-01"
               })

      assert resource.organization_id == scope.organization_id
    end

    test "desired spec changes advance generation and the ordered revision", %{scope: scope} do
      {:ok, resource} =
        Inventory.create_resource(scope, %{kind: "server", name: "compute-01", spec: %{}})

      assert {:ok, updated} =
               Inventory.update_resource(resource, %{spec: %{"power" => %{"policy" => "off"}}})

      assert updated.generation == resource.generation + 1
      assert updated.resource_version > resource.resource_version

      assert [%{action: "created"}, %{action: "updated"}] =
               Inventory.list_resource_revisions(scope, resource.id)
    end

    test "typed host fields remain queryable outside desired spec", %{scope: scope} do
      {:ok, resource} = Inventory.create_resource(scope, %{kind: "server", name: "compute-01"})

      assert {:ok, %Host{} = host} =
               Inventory.create_host(scope, resource.id, %{
                 hostname: "COMPUTE-01",
                 fqdn: "Compute-01.Example.Net",
                 vendor: "Dell Inc.",
                 model: "PowerEdge R760"
               })

      assert host.hostname == "compute-01"
      assert host.fqdn == "compute-01.example.net"
      assert Inventory.get_host_by_resource!(scope, resource.id).id == host.id
    end

    test "condition transitions are independent from lifecycle", %{scope: scope} do
      {:ok, resource} =
        Inventory.create_resource(scope, %{
          kind: "server",
          name: "compute-01",
          lifecycle_state: "active"
        })

      assert {:ok, %ResourceCondition{} = current} =
               Inventory.put_resource_condition(scope, resource.id, %{
                 type: "InventoryCurrent",
                 status: "true",
                 observed_generation: resource.generation
               })

      assert {:ok, unchanged} =
               Inventory.put_resource_condition(scope, resource.id, %{
                 type: "InventoryCurrent",
                 status: "true",
                 reason: "Refreshed"
               })

      assert unchanged.id == current.id
      assert unchanged.last_transition_at == current.last_transition_at
      assert Inventory.get_resource!(scope, resource.id).lifecycle_state == "active"
    end
  end

  describe "resource identifiers" do
    setup do
      contexts = scoped_organizations()

      {:ok, resource} =
        Inventory.create_resource(contexts.scope, %{
          kind: "server",
          name: "compute-01"
        })

      {:ok, source} =
        Inventory.create_source(contexts.scope, %{
          kind: "host_agent",
          name: "compute-01-agent"
        })

      {:ok, other_source} =
        Inventory.create_source(contexts.other_scope, %{
          kind: "host_agent",
          name: "compute-01-agent"
        })

      contexts
      |> Map.put(:resource, resource)
      |> Map.put(:source, source)
      |> Map.put(:other_source, other_source)
    end

    test "create_resource_identifier/3 stores observed identity facts", %{
      scope: scope,
      resource: resource,
      source: source
    } do
      now = Renga.Time.utc_now_ms()

      assert {:ok, %ResourceIdentifier{} = identifier} =
               Inventory.create_resource_identifier(scope, resource.id, %{
                 source_id: source.id,
                 kind: "machine_id",
                 value: " 9f3c ",
                 confidence: 95,
                 first_seen_at: now,
                 last_seen_at: now
               })

      assert identifier.organization_id == scope.organization_id
      assert identifier.resource_id == resource.id
      assert identifier.source_id == source.id
      assert identifier.value == "9f3c"
      assert identifier.confidence == 95
    end

    test "list_resource_identifiers/2 is scoped by organization", %{
      scope: scope,
      other_scope: other_scope,
      resource: resource
    } do
      {:ok, identifier} =
        Inventory.create_resource_identifier(scope, resource.id, %{
          kind: "hostname",
          value: "compute-01"
        })

      assert Inventory.list_resource_identifiers(scope, resource.id) == [identifier]
      assert Inventory.list_resource_identifiers(other_scope, resource.id) == []
    end

    test "create_resource_identifier/3 enforces resource organization scope", %{
      other_scope: other_scope,
      resource: resource
    } do
      assert_raise Ecto.NoResultsError, fn ->
        Inventory.create_resource_identifier(other_scope, resource.id, %{
          kind: "hostname",
          value: "compute-01"
        })
      end
    end

    test "create_resource_identifier/3 enforces source organization scope", %{
      scope: scope,
      resource: resource,
      other_source: other_source
    } do
      assert_raise Ecto.NoResultsError, fn ->
        Inventory.create_resource_identifier(scope, resource.id, %{
          source_id: other_source.id,
          kind: "hostname",
          value: "compute-01"
        })
      end
    end

    test "identifier uniqueness is scoped by source kind and value", %{
      scope: scope,
      resource: resource,
      source: source
    } do
      attrs = %{
        source_id: source.id,
        kind: "serial_number",
        value: "ABC123"
      }

      assert {:ok, _identifier} = Inventory.create_resource_identifier(scope, resource.id, attrs)
      assert {:error, changeset} = Inventory.create_resource_identifier(scope, resource.id, attrs)

      assert %{organization_id: ["has already been taken"]} = errors_on(changeset)
    end

    test "identifier validations reject unsupported kinds and confidence outside range", %{
      scope: scope,
      resource: resource
    } do
      assert {:error, changeset} =
               Inventory.create_resource_identifier(scope, resource.id, %{
                 kind: "unsupported",
                 value: "",
                 confidence: 101
               })

      assert %{
               kind: ["is invalid"],
               value: ["can't be blank"],
               confidence: ["must be less than or equal to 100"]
             } = errors_on(changeset)
    end
  end

  describe "interfaces" do
    setup do
      contexts = scoped_organizations()

      {:ok, resource} =
        Inventory.create_resource(contexts.scope, %{
          kind: "server",
          name: "compute-01"
        })

      {:ok, source} =
        Inventory.create_source(contexts.scope, %{
          kind: "host_agent",
          name: "compute-01-agent"
        })

      {:ok, other_source} =
        Inventory.create_source(contexts.other_scope, %{
          kind: "host_agent",
          name: "compute-01-agent"
        })

      contexts
      |> Map.put(:resource, resource)
      |> Map.put(:source, source)
      |> Map.put(:other_source, other_source)
    end

    test "create_interface/3 creates a scoped resource interface", %{
      scope: scope,
      resource: resource,
      source: source
    } do
      assert {:ok, %Interface{} = interface} =
               Inventory.create_interface(scope, resource.id, %{
                 source_id: source.id,
                 name: " eth0 ",
                 mac_address: " AA:BB:CC:DD:EE:FF ",
                 kind: "ethernet",
                 status: "up",
                 mtu: 1500,
                 speed_mbps: 10_000
               })

      assert interface.organization_id == scope.organization_id
      assert interface.resource_id == resource.id
      assert interface.source_id == source.id
      assert interface.name == "eth0"
      assert interface.mac_address == %Postgrex.MACADDR{address: {170, 187, 204, 221, 238, 255}}
    end

    test "list_interfaces/2 and get_interface!/2 are scoped by organization", %{
      scope: scope,
      other_scope: other_scope,
      resource: resource
    } do
      {:ok, interface} =
        Inventory.create_interface(scope, resource.id, %{
          name: "eth0"
        })

      assert Inventory.list_interfaces(scope, resource.id) == [interface]
      assert Inventory.get_interface!(scope, interface.id).id == interface.id

      assert Inventory.list_interfaces(other_scope, resource.id) == []

      assert_raise Ecto.NoResultsError, fn ->
        Inventory.get_interface!(other_scope, interface.id)
      end
    end

    test "create_interface/3 enforces resource organization scope", %{
      other_scope: other_scope,
      resource: resource
    } do
      assert_raise Ecto.NoResultsError, fn ->
        Inventory.create_interface(other_scope, resource.id, %{name: "eth0"})
      end
    end

    test "create_interface/3 enforces source organization scope", %{
      scope: scope,
      resource: resource,
      other_source: other_source
    } do
      assert_raise Ecto.NoResultsError, fn ->
        Inventory.create_interface(scope, resource.id, %{
          source_id: other_source.id,
          name: "eth0"
        })
      end
    end

    test "interface names are unique per resource", %{scope: scope, resource: resource} do
      attrs = %{name: "eth0"}

      assert {:ok, _interface} = Inventory.create_interface(scope, resource.id, attrs)
      assert {:error, changeset} = Inventory.create_interface(scope, resource.id, attrs)

      assert %{organization_id: ["has already been taken"]} = errors_on(changeset)
    end

    test "interface validations reject unsupported values", %{scope: scope, resource: resource} do
      assert {:error, changeset} =
               Inventory.create_interface(scope, resource.id, %{
                 name: "",
                 mac_address: "not-a-mac",
                 kind: "unsupported",
                 status: "missing",
                 mtu: 0,
                 speed_mbps: 0
               })

      assert %{
               name: ["can't be blank"],
               mac_address: ["is invalid"],
               kind: ["is invalid"],
               status: ["is invalid"],
               mtu: ["must be greater than 0"],
               speed_mbps: ["must be greater than 0"]
             } = errors_on(changeset)
    end
  end

  describe "interface relationships" do
    setup do
      contexts = scoped_organizations()

      {:ok, resource} =
        Inventory.create_resource(contexts.scope, %{
          kind: "server",
          name: "compute-01"
        })

      {:ok, other_resource} =
        Inventory.create_resource(contexts.other_scope, %{
          kind: "server",
          name: "other-compute-01"
        })

      {:ok, source} =
        Inventory.create_source(contexts.scope, %{
          kind: "host_agent",
          name: "compute-01-agent"
        })

      {:ok, other_source} =
        Inventory.create_source(contexts.other_scope, %{
          kind: "host_agent",
          name: "compute-01-agent"
        })

      {:ok, physical_interface} =
        Inventory.create_interface(contexts.scope, resource.id, %{
          name: "ens1f0np0",
          kind: "ethernet"
        })

      {:ok, bond_interface} =
        Inventory.create_interface(contexts.scope, resource.id, %{
          name: "bond0",
          kind: "bond"
        })

      {:ok, bridge_interface} =
        Inventory.create_interface(contexts.scope, resource.id, %{
          name: "br0",
          kind: "bridge"
        })

      {:ok, other_interface} =
        Inventory.create_interface(contexts.other_scope, other_resource.id, %{
          name: "ens1f0np0",
          kind: "ethernet"
        })

      contexts
      |> Map.put(:resource, resource)
      |> Map.put(:source, source)
      |> Map.put(:other_source, other_source)
      |> Map.put(:physical_interface, physical_interface)
      |> Map.put(:bond_interface, bond_interface)
      |> Map.put(:bridge_interface, bridge_interface)
      |> Map.put(:other_interface, other_interface)
    end

    test "create_interface_relationship/4 stores directed topology facts", %{
      scope: scope,
      source: source,
      physical_interface: physical_interface,
      bond_interface: bond_interface
    } do
      now = Renga.Time.utc_now_ms()

      assert {:ok, %InterfaceRelationship{} = relationship} =
               Inventory.create_interface_relationship(
                 scope,
                 physical_interface.id,
                 bond_interface.id,
                 %{
                   source_id: source.id,
                   kind: "lag_member",
                   metadata: %{"operational" => "enslaved"},
                   first_seen_at: now,
                   last_seen_at: now
                 }
               )

      assert relationship.organization_id == scope.organization_id
      assert relationship.source_interface_id == physical_interface.id
      assert relationship.target_interface_id == bond_interface.id
      assert relationship.source_id == source.id
      assert relationship.kind == "lag_member"
      assert relationship.metadata == %{"operational" => "enslaved"}
    end

    test "list_interface_relationships/2 returns relationships touching an interface", %{
      scope: scope,
      physical_interface: physical_interface,
      bond_interface: bond_interface,
      bridge_interface: bridge_interface
    } do
      {:ok, lag_relationship} =
        Inventory.create_interface_relationship(
          scope,
          physical_interface.id,
          bond_interface.id,
          %{kind: "lag_member"}
        )

      {:ok, bridge_relationship} =
        Inventory.create_interface_relationship(
          scope,
          bond_interface.id,
          bridge_interface.id,
          %{kind: "bridge_member"}
        )

      assert Inventory.list_interface_relationships(scope, bond_interface.id) == [
               bridge_relationship,
               lag_relationship
             ]
    end

    test "create_interface_relationship/4 enforces source and target organization scope", %{
      scope: scope,
      physical_interface: physical_interface,
      other_interface: other_interface
    } do
      assert_raise Ecto.NoResultsError, fn ->
        Inventory.create_interface_relationship(
          scope,
          physical_interface.id,
          other_interface.id,
          %{
            kind: "peer"
          }
        )
      end
    end

    test "create_interface_relationship/4 enforces provenance source organization scope", %{
      scope: scope,
      other_source: other_source,
      physical_interface: physical_interface,
      bond_interface: bond_interface
    } do
      assert_raise Ecto.NoResultsError, fn ->
        Inventory.create_interface_relationship(
          scope,
          physical_interface.id,
          bond_interface.id,
          %{
            source_id: other_source.id,
            kind: "lag_member"
          }
        )
      end
    end

    test "interface relationship uniqueness is scoped by source target and kind", %{
      scope: scope,
      physical_interface: physical_interface,
      bond_interface: bond_interface
    } do
      attrs = %{kind: "lag_member"}

      assert {:ok, _relationship} =
               Inventory.create_interface_relationship(
                 scope,
                 physical_interface.id,
                 bond_interface.id,
                 attrs
               )

      assert {:error, changeset} =
               Inventory.create_interface_relationship(
                 scope,
                 physical_interface.id,
                 bond_interface.id,
                 attrs
               )

      assert %{organization_id: ["has already been taken"]} = errors_on(changeset)
    end

    test "interface relationship validations reject unsupported kinds and self links", %{
      scope: scope,
      physical_interface: physical_interface,
      bond_interface: bond_interface
    } do
      assert {:error, changeset} =
               Inventory.create_interface_relationship(
                 scope,
                 physical_interface.id,
                 bond_interface.id,
                 %{kind: "unsupported"}
               )

      assert %{kind: ["is invalid"]} = errors_on(changeset)

      assert {:error, changeset} =
               Inventory.create_interface_relationship(
                 scope,
                 physical_interface.id,
                 physical_interface.id,
                 %{kind: "peer"}
               )

      assert %{target_interface_id: ["must be different from source interface"]} =
               errors_on(changeset)
    end
  end

  describe "addresses" do
    setup do
      contexts = scoped_organizations()

      {:ok, resource} =
        Inventory.create_resource(contexts.scope, %{
          kind: "server",
          name: "compute-01"
        })

      {:ok, interface} =
        Inventory.create_interface(contexts.scope, resource.id, %{
          name: "eth0"
        })

      {:ok, source} =
        Inventory.create_source(contexts.scope, %{
          kind: "host_agent",
          name: "compute-01-agent"
        })

      {:ok, other_source} =
        Inventory.create_source(contexts.other_scope, %{
          kind: "host_agent",
          name: "compute-01-agent"
        })

      contexts
      |> Map.put(:resource, resource)
      |> Map.put(:interface, interface)
      |> Map.put(:source, source)
      |> Map.put(:other_source, other_source)
    end

    test "create_address/3 creates a scoped interface address", %{
      scope: scope,
      resource: resource,
      interface: interface,
      source: source
    } do
      assert {:ok, %Address{} = address} =
               Inventory.create_address(scope, interface.id, %{
                 source_id: source.id,
                 kind: "ipv4",
                 address: " 192.0.2.10/24 ",
                 scope: "global"
               })

      assert address.organization_id == scope.organization_id
      assert address.resource_id == resource.id
      assert address.interface_id == interface.id
      assert address.source_id == source.id
      assert address.address == %Postgrex.INET{address: {192, 0, 2, 10}, netmask: 24}
    end

    test "list_addresses/2 is scoped by organization", %{
      scope: scope,
      other_scope: other_scope,
      interface: interface
    } do
      {:ok, address} =
        Inventory.create_address(scope, interface.id, %{
          kind: "ipv4",
          address: "192.0.2.10/24"
        })

      assert Inventory.list_addresses(scope, interface.id) == [address]
      assert Inventory.list_addresses(other_scope, interface.id) == []
    end

    test "create_address/3 enforces interface organization scope", %{
      other_scope: other_scope,
      interface: interface
    } do
      assert_raise Ecto.NoResultsError, fn ->
        Inventory.create_address(other_scope, interface.id, %{
          kind: "ipv4",
          address: "192.0.2.10"
        })
      end
    end

    test "create_address/3 enforces source organization scope", %{
      scope: scope,
      interface: interface,
      other_source: other_source
    } do
      assert_raise Ecto.NoResultsError, fn ->
        Inventory.create_address(scope, interface.id, %{
          source_id: other_source.id,
          kind: "ipv4",
          address: "192.0.2.10"
        })
      end
    end

    test "addresses are unique per interface", %{scope: scope, interface: interface} do
      attrs = %{
        kind: "ipv4",
        address: "192.0.2.10/24"
      }

      assert {:ok, _address} = Inventory.create_address(scope, interface.id, attrs)
      assert {:error, changeset} = Inventory.create_address(scope, interface.id, attrs)

      assert %{organization_id: ["has already been taken"]} = errors_on(changeset)
    end

    test "address validations enforce kind and native inet parsing", %{
      scope: scope,
      interface: interface
    } do
      assert {:error, changeset} =
               Inventory.create_address(scope, interface.id, %{
                 kind: "ipv4",
                 address: ""
               })

      assert %{
               address: ["can't be blank"]
             } = errors_on(changeset)

      assert {:error, changeset} =
               Inventory.create_address(scope, interface.id, %{
                 kind: "ipv4",
                 address: "2001:db8::1/64"
               })

      assert %{address: ["does not match kind"]} = errors_on(changeset)

      assert {:error, changeset} =
               Inventory.create_address(scope, interface.id, %{
                 kind: "ipv6",
                 address: "2001:db8::1/129"
               })

      assert %{address: ["is invalid"]} = errors_on(changeset)

      assert {:error, changeset} =
               Inventory.create_address(scope, interface.id, %{
                 kind: "bogus",
                 address: "2001:db8::1"
               })

      assert %{kind: ["is invalid"]} = errors_on(changeset)
    end
  end

  describe "sync runs" do
    setup do
      contexts = scoped_organizations()

      {:ok, source} =
        Inventory.create_source(contexts.scope, %{
          kind: "host_agent",
          name: "compute-01-agent"
        })

      contexts
      |> Map.put(:source, source)
    end

    test "create_sync_run/3 creates a scoped ingest batch", %{scope: scope, source: source} do
      assert {:ok, %SyncRun{} = sync_run} =
               Inventory.create_sync_run(scope, source.id, %{
                 status: "running",
                 resource_count: 2,
                 metadata: %{"collector" => "host-agent"}
               })

      assert sync_run.organization_id == scope.organization_id
      assert sync_run.source_id == source.id
      assert sync_run.status == "running"
      assert sync_run.resource_count == 2
      assert %DateTime{} = sync_run.started_at
    end

    test "list_sync_runs/1 and get_sync_run!/2 are scoped by organization", %{
      scope: scope,
      other_scope: other_scope,
      source: source
    } do
      {:ok, sync_run} = Inventory.create_sync_run(scope, source.id)

      assert Inventory.list_sync_runs(scope) == [sync_run]
      assert Inventory.get_sync_run!(scope, sync_run.id).id == sync_run.id
      assert Inventory.list_sync_runs(other_scope) == []

      assert_raise Ecto.NoResultsError, fn ->
        Inventory.get_sync_run!(other_scope, sync_run.id)
      end
    end

    test "create_sync_run/3 enforces source organization scope", %{
      other_scope: other_scope,
      source: source
    } do
      assert_raise Ecto.NoResultsError, fn ->
        Inventory.create_sync_run(other_scope, source.id)
      end
    end
  end

  describe "observations and change events" do
    setup do
      contexts = scoped_organizations()

      {:ok, resource} =
        Inventory.create_resource(contexts.scope, %{
          kind: "server",
          name: "compute-01"
        })

      {:ok, source} =
        Inventory.create_source(contexts.scope, %{
          kind: "host_agent",
          name: "compute-01-agent"
        })

      {:ok, sync_run} = Inventory.create_sync_run(contexts.scope, source.id)

      contexts
      |> Map.put(:resource, resource)
      |> Map.put(:source, source)
      |> Map.put(:sync_run, sync_run)
    end

    test "create_observation/3 stores raw payloads with a computed digest", %{
      scope: scope,
      resource: resource,
      source: source,
      sync_run: sync_run
    } do
      assert {:ok, %Observation{} = observation} =
               Inventory.create_observation(scope, source.id, %{
                 resource_id: resource.id,
                 sync_run_id: sync_run.id,
                 observation_id: " host-agent:compute-01 ",
                 payload: %{"hostname" => "compute-01", "serial" => "ABC123"}
               })

      assert observation.organization_id == scope.organization_id
      assert observation.source_id == source.id
      assert observation.resource_id == resource.id
      assert observation.sync_run_id == sync_run.id
      assert String.at(observation.id, 14) == "7"
      assert observation.observation_id == "host-agent:compute-01"
      assert is_binary(observation.payload_digest)
      refute Map.has_key?(observation, :updated_at)

      {:ok, <<uuid_unix_ms::48, _rest::binary>>} = Ecto.UUID.dump(observation.id)
      assert observation.inserted_at == Renga.Time.from_unix_ms!(uuid_unix_ms)
    end

    test "list_observations/2 is scoped by organization", %{
      scope: scope,
      other_scope: other_scope,
      resource: resource,
      source: source
    } do
      {:ok, observation} =
        Inventory.create_observation(scope, source.id, %{
          resource_id: resource.id,
          payload: %{"hostname" => "compute-01"}
        })

      assert Inventory.list_observations(scope, resource.id) == [observation]
      assert Inventory.list_observations(other_scope, resource.id) == []
    end

    test "observations are unique by source observation id and payload digest", %{
      scope: scope,
      resource: resource,
      source: source
    } do
      attrs = %{
        resource_id: resource.id,
        observation_id: "host-agent:compute-01",
        payload: %{"hostname" => "compute-01"}
      }

      assert {:ok, _observation} = Inventory.create_observation(scope, source.id, attrs)

      assert {:error, changeset} =
               Inventory.create_observation(scope, source.id, %{
                 attrs
                 | payload: %{"hostname" => "compute-01-updated"}
               })

      assert %{organization_id: ["has already been taken"]} = errors_on(changeset)

      assert {:error, changeset} =
               Inventory.create_observation(scope, source.id, %{
                 resource_id: resource.id,
                 payload: %{"hostname" => "compute-01"}
               })

      assert %{organization_id: ["has already been taken"]} = errors_on(changeset)
    end

    test "create_observation/3 enforces linked resource organization scope", %{
      other_scope: other_scope,
      resource: resource,
      source: source
    } do
      assert_raise Ecto.NoResultsError, fn ->
        Inventory.create_observation(other_scope, source.id, %{
          resource_id: resource.id,
          payload: %{"hostname" => "compute-01"}
        })
      end
    end

    test "create_change_event/2 records scoped audit entries", %{
      scope: scope,
      resource: resource,
      source: source,
      sync_run: sync_run
    } do
      {:ok, observation} =
        Inventory.create_observation(scope, source.id, %{
          resource_id: resource.id,
          sync_run_id: sync_run.id,
          payload: %{"hostname" => "compute-01"}
        })

      assert {:ok, %ChangeEvent{} = change_event} =
               Inventory.create_change_event(scope, %{
                 resource_id: resource.id,
                 source_id: source.id,
                 sync_run_id: sync_run.id,
                 observation_id: observation.id,
                 kind: "updated",
                 field: " status ",
                 old_value: %{"value" => "unknown"},
                 new_value: %{"value" => "active"}
               })

      assert change_event.organization_id == scope.organization_id
      assert change_event.resource_id == resource.id
      assert change_event.source_id == source.id
      assert change_event.sync_run_id == sync_run.id
      assert change_event.observation_id == observation.id
      assert change_event.field == "status"
      assert %DateTime{} = change_event.occurred_at
    end

    test "list_change_events/2 is scoped by organization", %{
      scope: scope,
      other_scope: other_scope,
      resource: resource
    } do
      {:ok, change_event} =
        Inventory.create_change_event(scope, %{
          resource_id: resource.id,
          kind: "discovered"
        })

      assert Inventory.list_change_events(scope, resource.id) == [change_event]
      assert Inventory.list_change_events(other_scope, resource.id) == []
    end

    test "create_change_event/2 enforces linked resource organization scope", %{
      other_scope: other_scope,
      resource: resource
    } do
      assert_raise Ecto.NoResultsError, fn ->
        Inventory.create_change_event(other_scope, %{
          resource_id: resource.id,
          kind: "discovered"
        })
      end
    end

    test "change event validations reject unsupported kinds", %{scope: scope} do
      assert {:error, changeset} =
               Inventory.create_change_event(scope, %{
                 kind: "unsupported"
               })

      assert %{kind: ["is invalid"]} = errors_on(changeset)
    end
  end

  describe "resource overrides and freshness" do
    setup do
      contexts = scoped_organizations()

      {:ok, resource} =
        Inventory.create_resource(contexts.scope, %{
          kind: "server",
          name: "compute-01",
          lifecycle_state: "active"
        })

      contexts
      |> Map.put(:resource, resource)
    end

    test "create_resource_override/3 stores scoped manual overrides with actor attribution", %{
      scope: scope,
      resource: resource
    } do
      {:ok, user} =
        Accounts.register_user(%{
          email: "operator#{System.unique_integer()}@example.com"
        })

      scope = %{scope | user: user}

      assert {:ok, %ResourceOverride{} = override} =
               Inventory.create_resource_override(scope, resource.id, %{
                 field: " hostname ",
                 value: %{"value" => "manual-compute-01"},
                 reason: " vendor feed is stale ",
                 created_by_user_id: Ecto.UUID.generate()
               })

      assert override.organization_id == scope.organization_id
      assert override.resource_id == resource.id
      assert override.created_by_user_id == user.id
      assert override.field == "hostname"
      assert override.reason == "vendor feed is stale"
      assert override.value == %{"value" => "manual-compute-01"}
    end

    test "list_resource_overrides/2 is scoped by organization", %{
      scope: scope,
      other_scope: other_scope,
      resource: resource
    } do
      {:ok, override} =
        Inventory.create_resource_override(scope, resource.id, %{
          field: "status",
          value: %{"value" => "maintenance"}
        })

      assert Inventory.list_resource_overrides(scope, resource.id) == [override]
      assert Inventory.list_resource_overrides(other_scope, resource.id) == []
    end

    test "create_resource_override/3 enforces resource organization scope", %{
      other_scope: other_scope,
      resource: resource
    } do
      assert_raise Ecto.NoResultsError, fn ->
        Inventory.create_resource_override(other_scope, resource.id, %{
          field: "status",
          value: %{"value" => "maintenance"}
        })
      end
    end

    test "resource override uniqueness is scoped by resource field", %{
      scope: scope,
      resource: resource
    } do
      attrs = %{
        field: "status",
        value: %{"value" => "maintenance"}
      }

      assert {:ok, _override} = Inventory.create_resource_override(scope, resource.id, attrs)
      assert {:error, changeset} = Inventory.create_resource_override(scope, resource.id, attrs)

      assert %{organization_id: ["has already been taken"]} = errors_on(changeset)
    end

    test "resource override validations reject missing values", %{
      scope: scope,
      resource: resource
    } do
      assert {:error, changeset} =
               Inventory.create_resource_override(scope, resource.id, %{
                 field: "",
                 value: nil
               })

      assert %{
               field: ["can't be blank"],
               value: ["can't be blank"]
             } = errors_on(changeset)
    end

    test "mark_resource_stale/3 records a scoped freshness transition", %{
      scope: scope,
      resource: resource
    } do
      stale_at = Renga.Time.utc_now_ms()

      assert {:ok, condition} = Inventory.mark_resource_stale(scope, resource.id, stale_at)

      assert condition.status == "false"
      assert condition.reason == "Stale"
      assert condition.last_transition_at == stale_at
      assert Inventory.get_resource!(scope, resource.id).lifecycle_state == "active"
    end

    test "mark_resource_stale/3 enforces resource organization scope", %{
      other_scope: other_scope,
      resource: resource
    } do
      assert_raise Ecto.NoResultsError, fn ->
        Inventory.mark_resource_stale(other_scope, resource.id)
      end
    end
  end
end
