defmodule Renga.InventoryTest do
  use Renga.DataCase, async: true

  alias Renga.Accounts
  alias Renga.Inventory
  alias Renga.Inventory.Address
  alias Renga.Inventory.AddressEvidence
  alias Renga.Inventory.Agent
  alias Renga.Inventory.AgentLease
  alias Renga.Inventory.ChangeEvent
  alias Renga.Inventory.Host
  alias Renga.Inventory.Interface
  alias Renga.Inventory.InterfaceEvidence
  alias Renga.Inventory.InterfaceRelationship
  alias Renga.Inventory.InterfaceRelationshipEvidence
  alias Renga.Inventory.Observation
  alias Renga.Inventory.ObservationReconciliation
  alias Renga.Inventory.Prefix
  alias Renga.Inventory.Resource
  alias Renga.Inventory.ResourceCondition
  alias Renga.Inventory.ResourceIdentifier
  alias Renga.Inventory.ResourceIdentifierClaim
  alias Renga.Inventory.ResourceOverride
  alias Renga.Inventory.ResourceOwner
  alias Renga.Inventory.ResourceRelationship
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
                 metadata: %{"interval_seconds" => 60}
               })

      assert {:ok, _uuid} = Ecto.UUID.cast(source.id)
      assert source.organization_id == scope.organization_id
      assert source.status == "active"
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

  describe "agents and leases" do
    setup do
      contexts = scoped_organizations()

      {:ok, source} =
        Inventory.create_source(contexts.scope, %{
          kind: "host_agent",
          name: "iad-1-host-agent"
        })

      Map.put(contexts, :source, source)
    end

    test "check-in registers an agent separately from source credentials", %{
      scope: scope,
      source: source
    } do
      assert {:ok, {%Agent{} = agent, %AgentLease{} = lease}} =
               Inventory.record_agent_check_in(scope, source.id, %{
                 capabilities: ["host.inventory"],
                 metadata: %{"agent_version" => "0.1.0", "kernel" => "6.12"}
               })

      assert agent.source_id == source.id
      assert agent.version == "0.1.0"
      assert agent.capabilities == ["host.inventory"]
      assert lease.agent_id == agent.id
      assert DateTime.compare(lease.expires_at, lease.renewed_at) == :gt
      refute Map.has_key?(source, :last_seen_at)
      refute Map.has_key?(source, :capabilities)
    end

    test "renewal updates one lease and expiry is deterministic", %{scope: scope, source: source} do
      {:ok, {agent, original}} = Inventory.record_agent_check_in(scope, source.id)
      renewed_at = ~U[2030-08-01 12:00:00.000000Z]

      assert {:ok, renewed} =
               Inventory.renew_agent_lease(scope, agent.id, %{
                 renewed_at: renewed_at,
                 ttl_ms: 1_500
               })

      assert renewed.id == original.id
      assert renewed.expires_at == ~U[2030-08-01 12:00:01.500000Z]
      refute AgentLease.expired?(renewed, ~U[2030-08-01 12:00:01.499000Z])
      assert AgentLease.expired?(renewed, ~U[2030-08-01 12:00:01.500000Z])
      assert Inventory.get_agent_lease!(scope, agent.id).id == renewed.id
    end

    test "an older renewal cannot shorten the current lease", %{scope: scope, source: source} do
      {:ok, {agent, _original}} = Inventory.record_agent_check_in(scope, source.id)

      assert {:ok, current} =
               Inventory.renew_agent_lease(scope, agent.id, %{
                 renewed_at: ~U[2030-08-01 12:00:00.000000Z],
                 ttl_ms: 90_000
               })

      assert {:ok, replayed} =
               Inventory.renew_agent_lease(scope, agent.id, %{
                 renewed_at: ~U[2029-08-01 12:00:00.000000Z],
                 ttl_ms: 1_000
               })

      assert replayed.renewed_at == current.renewed_at
      assert replayed.expires_at == current.expires_at

      stored = Inventory.get_agent_lease!(scope, agent.id)
      assert stored.renewed_at == current.renewed_at
      assert stored.expires_at == current.expires_at
    end

    test "repeated check-ins reuse registration and lease while merging metadata", %{
      scope: scope,
      source: source
    } do
      assert {:ok, {original_agent, original_lease}} =
               Inventory.record_agent_check_in(scope, source.id, %{
                 capabilities: ["host.inventory"],
                 metadata: %{"agent_version" => "0.1.0", "kernel" => "6.12"}
               })

      assert {:ok, {updated_agent, updated_lease}} =
               Inventory.record_agent_check_in(scope, source.id, %{
                 capabilities: ["host.inventory", "host.network"],
                 metadata: %{"agent_version" => "0.2.0"}
               })

      assert updated_agent.id == original_agent.id
      assert updated_agent.registered_at == original_agent.registered_at
      assert updated_agent.version == "0.2.0"
      assert updated_agent.capabilities == ["host.inventory", "host.network"]
      assert updated_agent.metadata == %{"agent_version" => "0.2.0", "kernel" => "6.12"}
      assert updated_lease.id == original_lease.id
      assert DateTime.compare(updated_lease.renewed_at, original_lease.renewed_at) in [:eq, :gt]

      assert {:ok, {unchanged_agent, _lease}} =
               Inventory.record_agent_check_in(scope, source.id)

      assert unchanged_agent.version == updated_agent.version
      assert unchanged_agent.capabilities == updated_agent.capabilities
      assert unchanged_agent.metadata == updated_agent.metadata
    end

    test "agent capabilities are validated on registration", %{scope: scope, source: source} do
      assert {:error, changeset} =
               Inventory.record_agent_check_in(scope, source.id, %{
                 capabilities: ["host.inventory", "   "]
               })

      assert %{capabilities: ["must contain only non-empty strings"]} = errors_on(changeset)
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

    test "update_resource/3 rejects a resource outside the caller's organization", %{
      scope: scope,
      other_scope: other_scope
    } do
      {:ok, resource} =
        Inventory.create_resource(scope, %{kind: "server", name: "compute-01"})

      forged_resource = %Resource{id: resource.id}

      assert_raise Ecto.NoResultsError, fn ->
        Inventory.update_resource(other_scope, forged_resource, %{display_name: "Compromised"})
      end

      assert Inventory.get_resource!(scope, resource.id).display_name == nil
    end

    test "desired spec changes advance generation and the ordered revision", %{scope: scope} do
      {:ok, resource} =
        Inventory.create_resource(scope, %{kind: "server", name: "compute-01", spec: %{}})

      assert {:ok, updated} =
               Inventory.update_resource(scope, resource, %{
                 spec: %{"power" => %{"policy" => "off"}}
               })

      assert updated.generation == resource.generation + 1
      assert updated.resource_version > resource.resource_version

      assert [%{action: "created"}, %{action: "updated"}] =
               Inventory.list_resource_revisions(scope, resource.id)
    end

    test "metadata changes preserve generation while advancing resource version", %{scope: scope} do
      {:ok, resource} =
        Inventory.create_resource(scope, %{
          kind: "server",
          name: "compute-01",
          spec: %{"power" => %{"policy" => "on"}}
        })

      assert {:ok, updated} =
               Inventory.update_resource(scope, resource, %{
                 display_name: "Compute 01",
                 labels: %{"site" => "iad"},
                 annotations: %{"owner" => "platform"}
               })

      assert updated.generation == resource.generation
      assert updated.resource_version > resource.resource_version

      assert [created, changed] = Inventory.list_resource_revisions(scope, resource.id)
      assert created.generation == changed.generation
      assert changed.snapshot["labels"] == %{"site" => "iad"}
      assert changed.snapshot["annotations"] == %{"owner" => "platform"}
    end

    test "equal desired spec does not increment generation", %{scope: scope} do
      spec = %{"power" => %{"policy" => "on"}}

      {:ok, resource} =
        Inventory.create_resource(scope, %{kind: "server", name: "compute-01", spec: spec})

      assert {:ok, updated} = Inventory.update_resource(scope, resource, %{spec: spec})
      assert updated.generation == resource.generation
      assert updated.resource_version > resource.resource_version
    end

    test "resource revisions are globally ordered and classify deletion requests", %{scope: scope} do
      {:ok, first} = Inventory.create_resource(scope, %{kind: "server", name: "compute-01"})
      {:ok, second} = Inventory.create_resource(scope, %{kind: "server", name: "compute-02"})
      deletion_requested_at = ~U[2026-08-03 12:00:00.000000Z]

      assert second.resource_version > first.resource_version

      assert {:ok, deleting} =
               Inventory.update_resource(scope, first, %{
                 deletion_requested_at: deletion_requested_at
               })

      assert deleting.resource_version > second.resource_version

      assert [%{action: "created"}, deletion_revision] =
               Inventory.list_resource_revisions(scope, first.id)

      assert deletion_revision.action == "deletion_requested"
      assert deletion_revision.revision == deleting.resource_version
    end

    test "updates after a deletion request remain classified as updates", %{scope: scope} do
      {:ok, resource} =
        Inventory.create_resource(scope, %{kind: "server", name: "compute-01"})

      assert {:ok, deleting} =
               Inventory.update_resource(scope, resource, %{
                 deletion_requested_at: ~U[2026-08-03 12:00:00.000000Z]
               })

      assert {:ok, _updated} =
               Inventory.update_resource(scope, deleting, %{labels: %{"site" => "iad"}})

      assert [%{action: "created"}, %{action: "deletion_requested"}, %{action: "updated"}] =
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

      transition_at = DateTime.add(current.last_transition_at, 1, :millisecond)

      assert {:ok, stale} =
               Inventory.put_resource_condition(scope, resource.id, %{
                 type: "InventoryCurrent",
                 status: "false",
                 reason: "Stale",
                 last_transition_at: transition_at
               })

      assert stale.id == current.id
      assert stale.last_transition_at == transition_at
      assert Inventory.get_resource!(scope, resource.id).lifecycle_state == "active"
    end

    test "condition transitions accept string-keyed attributes", %{scope: scope} do
      {:ok, resource} =
        Inventory.create_resource(scope, %{kind: "server", name: "compute-01"})

      assert {:ok, %ResourceCondition{} = condition} =
               Inventory.put_resource_condition(scope, resource.id, %{
                 "type" => "Ready",
                 "status" => "true"
               })

      assert condition.type == "Ready"
      assert condition.status == "true"
      assert %DateTime{} = condition.last_transition_at
    end
  end

  describe "resource topology and ownership" do
    setup do
      contexts = scoped_organizations()
      {:ok, host} = Inventory.create_resource(contexts.scope, %{kind: "server", name: "host-01"})
      {:ok, vm} = Inventory.create_resource(contexts.scope, %{kind: "vm", name: "vm-01"})

      {:ok, manager} =
        Inventory.create_resource(contexts.scope, %{kind: "server", name: "manager-01"})

      contexts
      |> Map.put(:host, host)
      |> Map.put(:vm, vm)
      |> Map.put(:manager, manager)
    end

    test "cross-domain topology has no lifecycle ownership semantics", %{
      scope: scope,
      host: host,
      vm: vm
    } do
      assert {:ok, %ResourceRelationship{} = relationship} =
               Inventory.create_resource_relationship(scope, vm.id, host.id, %{
                 kind: "hosted_on",
                 metadata: %{"hypervisor" => "libvirt"}
               })

      assert relationship.source_resource_id == vm.id
      assert relationship.target_resource_id == host.id
      assert Inventory.list_resource_owners(scope, vm.id) == []
    end

    test "one controller owns lifecycle while non-controller references remain possible", %{
      scope: scope,
      host: host,
      vm: vm,
      manager: manager
    } do
      assert {:ok, %ResourceOwner{} = owner} =
               Inventory.create_resource_owner(scope, host.id, vm.id, %{
                 kind: "libvirt_domain",
                 controller: true
               })

      assert {:error, changeset} =
               Inventory.create_resource_owner(scope, manager.id, vm.id, %{
                 kind: "agent_managed",
                 controller: true
               })

      assert %{organization_id: ["has already been taken"]} = errors_on(changeset)

      assert {:ok, reference} =
               Inventory.create_resource_owner(scope, manager.id, vm.id, %{
                 kind: "agent_managed",
                 controller: false
               })

      assert Inventory.list_resource_owners(scope, vm.id) == [owner, reference]
      refute Map.has_key?(vm, :finalizers)
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

      {:ok, second_source} =
        Inventory.create_source(contexts.scope, %{
          kind: "host_agent",
          name: "rack-discovery"
        })

      {:ok, observation} =
        Inventory.create_observation(contexts.scope, source.id, %{
          observation_id: "agent-report-1",
          observed_at: ~U[2026-08-01 12:00:00.000000Z],
          payload: %{"serial_number" => "ABC123"}
        })

      {:ok, second_observation} =
        Inventory.create_observation(contexts.scope, second_source.id, %{
          observation_id: "rack-report-1",
          observed_at: ~U[2026-08-01 12:01:00.000000Z],
          payload: %{"serial_number" => "ABC123"}
        })

      contexts
      |> Map.put(:resource, resource)
      |> Map.put(:source, source)
      |> Map.put(:second_source, second_source)
      |> Map.put(:observation, observation)
      |> Map.put(:second_observation, second_observation)
    end

    test "create_resource_identifier/3 stores normalized canonical identity", %{
      scope: scope,
      resource: resource
    } do
      assert {:ok, %ResourceIdentifier{} = identifier} =
               Inventory.create_resource_identifier(scope, resource.id, %{
                 kind: "machine_id",
                 value: " 9F3C "
               })

      assert identifier.organization_id == scope.organization_id
      assert identifier.resource_id == resource.id
      assert identifier.value == "9F3C"
      assert identifier.normalized_value == "9f3c"
    end

    test "MAC address normalization canonicalizes case and delimiters", %{
      scope: scope,
      resource: resource,
      source: source,
      observation: observation
    } do
      assert {:ok, identifier} =
               Inventory.create_resource_identifier(scope, resource.id, %{
                 kind: "mac_address",
                 value: "AA-BB-CC-DD-EE-FF"
               })

      assert identifier.normalized_value == "aa:bb:cc:dd:ee:ff"

      assert {:ok, claim} =
               Inventory.create_resource_identifier_claim(
                 scope,
                 source.id,
                 observation.id,
                 %{
                   resource_id: resource.id,
                   resource_identifier_id: identifier.id,
                   kind: "mac_address",
                   value: "aa:bb:cc:dd:ee:ff"
                 }
               )

      assert claim.normalized_value == identifier.normalized_value

      assert {:error, changeset} =
               Inventory.create_resource_identifier(scope, resource.id, %{
                 kind: "mac_address",
                 value: "aa:bb:cc:dd:ee:ff"
               })

      assert %{organization_id: ["has already been taken"]} = errors_on(changeset)
    end

    test "opaque provider identifiers preserve case", %{scope: scope, resource: resource} do
      assert {:ok, upper_identifier} =
               Inventory.create_resource_identifier(scope, resource.id, %{
                 kind: "provider_instance_id",
                 value: "instance-ABC123"
               })

      assert {:ok, lower_identifier} =
               Inventory.create_resource_identifier(scope, resource.id, %{
                 kind: "provider_instance_id",
                 value: "instance-abc123"
               })

      assert upper_identifier.normalized_value == "instance-ABC123"
      assert lower_identifier.normalized_value == "instance-abc123"
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

    test "duplicate identifiers can be represented on separate resources", %{
      scope: scope,
      resource: resource
    } do
      {:ok, duplicate_resource} =
        Inventory.create_resource(scope, %{kind: "server", name: "compute-02"})

      attrs = %{kind: "serial_number", value: "ABC123"}

      assert {:ok, _identifier} = Inventory.create_resource_identifier(scope, resource.id, attrs)

      assert {:ok, _duplicate_identifier} =
               Inventory.create_resource_identifier(scope, duplicate_resource.id, attrs)
    end

    test "multiple sources can agree or conflict through claims", %{
      scope: scope,
      resource: resource,
      source: source,
      second_source: second_source,
      observation: observation,
      second_observation: second_observation
    } do
      {:ok, identifier} =
        Inventory.create_resource_identifier(scope, resource.id, %{
          kind: "serial_number",
          value: "ABC123"
        })

      assert {:ok, %ResourceIdentifierClaim{} = agent_claim} =
               Inventory.create_resource_identifier_claim(
                 scope,
                 source.id,
                 observation.id,
                 %{
                   resource_id: resource.id,
                   resource_identifier_id: identifier.id,
                   kind: "serial_number",
                   value: "ABC123",
                   confidence: 100
                 }
               )

      assert {:ok, rack_claim} =
               Inventory.create_resource_identifier_claim(
                 scope,
                 second_source.id,
                 second_observation.id,
                 %{
                   resource_id: resource.id,
                   kind: "serial_number",
                   value: "CONFLICTING-SERIAL",
                   confidence: 80
                 }
               )

      assert agent_claim.normalized_value == "ABC123"
      assert agent_claim.resource_identifier_id == identifier.id
      assert rack_claim.normalized_value == "CONFLICTING-SERIAL"

      assert Inventory.list_resource_identifier_claims(scope, resource.id) == [
               agent_claim,
               rack_claim
             ]
    end

    test "claim source must own the immutable observation", %{
      scope: scope,
      second_source: second_source,
      observation: observation
    } do
      assert_raise Ecto.NoResultsError, fn ->
        Inventory.create_resource_identifier_claim(
          scope,
          second_source.id,
          observation.id,
          %{kind: "serial_number", value: "ABC123"}
        )
      end
    end

    test "claim validations reject unsupported kinds and confidence outside range", %{
      scope: scope,
      source: source,
      observation: observation
    } do
      assert {:error, changeset} =
               Inventory.create_resource_identifier_claim(scope, source.id, observation.id, %{
                 kind: "unsupported",
                 value: "",
                 confidence: 101
               })

      assert %{kind: ["is invalid"], value: ["can't be blank"]} = errors_on(changeset)
      assert "must be less than or equal to 100" in errors_on(changeset).confidence
    end

    test "claim defaults support string-keyed params", %{
      scope: scope,
      source: source,
      observation: observation
    } do
      assert {:ok, claim} =
               Inventory.create_resource_identifier_claim(
                 scope,
                 source.id,
                 observation.id,
                 %{"kind" => "serial_number", "value" => "ABC123"}
               )

      assert claim.first_seen_at == observation.observed_at
      assert claim.last_seen_at == observation.observed_at
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
      resource: resource
    } do
      assert {:ok, %Interface{} = interface} =
               Inventory.create_interface(scope, resource.id, %{
                 name: " eth0 ",
                 mac_address: " AA:BB:CC:DD:EE:FF ",
                 kind: "ethernet",
                 status: "up",
                 mtu: 1500,
                 speed_mbps: 10_000
               })

      assert interface.organization_id == scope.organization_id
      assert interface.resource_id == resource.id
      refute Map.has_key?(interface, :source_id)
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
      physical_interface: physical_interface,
      bond_interface: bond_interface
    } do
      assert {:ok, %InterfaceRelationship{} = relationship} =
               Inventory.create_interface_relationship(
                 scope,
                 physical_interface.id,
                 bond_interface.id,
                 %{
                   kind: "lag_member",
                   metadata: %{"operational" => "enslaved"}
                 }
               )

      assert relationship.organization_id == scope.organization_id
      assert relationship.source_interface_id == physical_interface.id
      assert relationship.target_interface_id == bond_interface.id
      refute Map.has_key?(relationship, :source_id)
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
      interface: interface
    } do
      assert {:ok, %Address{} = address} =
               Inventory.create_address(scope, interface.id, %{
                 kind: "ipv4",
                 address: " 192.0.2.10/24 ",
                 scope: "global"
               })

      assert address.organization_id == scope.organization_id
      assert address.resource_id == resource.id
      assert address.interface_id == interface.id
      refute Map.has_key?(address, :source_id)
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

  describe "network evidence" do
    setup do
      contexts = scoped_organizations()

      {:ok, resource} =
        Inventory.create_resource(contexts.scope, %{kind: "server", name: "compute-01"})

      {:ok, source} =
        Inventory.create_source(contexts.scope, %{
          kind: "host_agent",
          name: "compute-01-agent"
        })

      {:ok, observation} =
        Inventory.create_observation(contexts.scope, source.id, %{
          observation_id: "network-report-1",
          observed_at: ~U[2026-08-01 12:00:00.000000Z],
          payload: %{"interfaces" => []}
        })

      {:ok, second_source} =
        Inventory.create_source(contexts.scope, %{
          kind: "vm_provider",
          name: "libvirt-discovery"
        })

      {:ok, second_observation} =
        Inventory.create_observation(contexts.scope, second_source.id, %{
          observation_id: "network-report-2",
          observed_at: ~U[2026-08-03 12:01:00.000000Z],
          payload: %{"interfaces" => []}
        })

      {:ok, physical} =
        Inventory.create_interface(contexts.scope, resource.id, %{
          name: "ens1f0np0",
          kind: "ethernet"
        })

      {:ok, bond} =
        Inventory.create_interface(contexts.scope, resource.id, %{name: "bond0", kind: "bond"})

      {:ok, address} =
        Inventory.create_address(contexts.scope, physical.id, %{
          kind: "ipv4",
          address: "192.0.2.10/24"
        })

      {:ok, relationship} =
        Inventory.create_interface_relationship(
          contexts.scope,
          physical.id,
          bond.id,
          %{kind: "lag_member"}
        )

      contexts
      |> Map.put(:source, source)
      |> Map.put(:observation, observation)
      |> Map.put(:second_source, second_source)
      |> Map.put(:second_observation, second_observation)
      |> Map.put(:physical, physical)
      |> Map.put(:address, address)
      |> Map.put(:relationship, relationship)
    end

    test "retains typed source evidence without source-owned canonical rows", context do
      assert {:ok, %InterfaceEvidence{} = interface_evidence} =
               Inventory.create_interface_evidence(
                 context.scope,
                 context.source.id,
                 context.observation.id,
                 context.physical.id,
                 %{
                   name: "ens1f0np0",
                   kind: "ethernet",
                   status: "up",
                   mac_address: "aa:bb:cc:dd:ee:ff"
                 }
               )

      assert {:ok, %AddressEvidence{} = address_evidence} =
               Inventory.create_address_evidence(
                 context.scope,
                 context.source.id,
                 context.observation.id,
                 context.address.id,
                 %{address: "192.0.2.10/24", scope: "global"}
               )

      assert {:ok, %InterfaceRelationshipEvidence{} = relationship_evidence} =
               Inventory.create_interface_relationship_evidence(
                 context.scope,
                 context.source.id,
                 context.observation.id,
                 context.relationship.id,
                 %{kind: "lag_member"}
               )

      assert interface_evidence.source_id == context.source.id
      assert address_evidence.address == context.address.address
      assert relationship_evidence.observation_id == context.observation.id
      refute Map.has_key?(context.physical, :source_id)
      refute Map.has_key?(context.address, :source_id)
      refute Map.has_key?(context.relationship, :source_id)
    end

    test "evidence defaults support string-keyed params", context do
      assert {:ok, interface_evidence} =
               Inventory.create_interface_evidence(
                 context.scope,
                 context.source.id,
                 context.observation.id,
                 context.physical.id,
                 %{"name" => "ens1f0np0", "kind" => "ethernet", "status" => "up"}
               )

      assert {:ok, address_evidence} =
               Inventory.create_address_evidence(
                 context.scope,
                 context.source.id,
                 context.observation.id,
                 context.address.id,
                 %{"address" => "192.0.2.10/24", "scope" => "global"}
               )

      assert {:ok, relationship_evidence} =
               Inventory.create_interface_relationship_evidence(
                 context.scope,
                 context.source.id,
                 context.observation.id,
                 context.relationship.id,
                 %{"kind" => "lag_member"}
               )

      assert interface_evidence.observed_at == context.observation.observed_at
      assert address_evidence.observed_at == context.observation.observed_at
      assert relationship_evidence.observed_at == context.observation.observed_at
    end

    test "multiple sources can retain conflicting interface evidence", context do
      assert {:ok, host_evidence} =
               Inventory.create_interface_evidence(
                 context.scope,
                 context.source.id,
                 context.observation.id,
                 context.physical.id,
                 %{
                   name: "ens1f0np0",
                   kind: "ethernet",
                   status: "up",
                   mac_address: "aa:bb:cc:dd:ee:ff"
                 }
               )

      assert {:ok, hypervisor_evidence} =
               Inventory.create_interface_evidence(
                 context.scope,
                 context.second_source.id,
                 context.second_observation.id,
                 context.physical.id,
                 %{
                   name: "ens1f0np0",
                   kind: "virtual",
                   status: "down",
                   mac_address: "aa:bb:cc:dd:ee:00"
                 }
               )

      assert host_evidence.interface_id == hypervisor_evidence.interface_id
      refute host_evidence.source_id == hypervisor_evidence.source_id
      refute host_evidence.kind == hypervisor_evidence.kind
      refute host_evidence.mac_address == hypervisor_evidence.mac_address

      canonical = Inventory.get_interface!(context.scope, context.physical.id)
      assert canonical.kind == "ethernet"
      assert canonical.status == "unknown"
      assert canonical.mac_address == nil
    end

    test "evidence requires the authenticated source's own observation", context do
      assert_raise Ecto.NoResultsError, fn ->
        Inventory.create_interface_evidence(
          context.scope,
          context.second_source.id,
          context.observation.id,
          context.physical.id,
          %{name: "ens1f0np0", kind: "ethernet", status: "up"}
        )
      end
    end

    test "evidence cannot cross organization boundaries", context do
      {:ok, other_source} =
        Inventory.create_source(context.other_scope, %{
          kind: "host_agent",
          name: "other-agent"
        })

      {:ok, other_observation} =
        Inventory.create_observation(context.other_scope, other_source.id, %{
          observation_id: "other-network-report",
          payload: %{"interfaces" => []}
        })

      assert_raise Ecto.NoResultsError, fn ->
        Inventory.create_interface_evidence(
          context.scope,
          other_source.id,
          other_observation.id,
          context.physical.id,
          %{name: "ens1f0np0", kind: "ethernet", status: "up"}
        )
      end
    end

    test "one observation cannot assert the same canonical interface twice", context do
      attrs = %{name: "ens1f0np0", kind: "ethernet", status: "up"}

      assert {:ok, _evidence} =
               Inventory.create_interface_evidence(
                 context.scope,
                 context.source.id,
                 context.observation.id,
                 context.physical.id,
                 attrs
               )

      assert {:error, changeset} =
               Inventory.create_interface_evidence(
                 context.scope,
                 context.source.id,
                 context.observation.id,
                 context.physical.id,
                 attrs
               )

      assert %{organization_id: ["has already been taken"]} = errors_on(changeset)
    end
  end

  describe "prefixes" do
    test "stores managed IPAM networks using PostgreSQL cidr" do
      %{scope: scope} = scoped_organizations()
      {:ok, resource} = Inventory.create_resource(scope, %{kind: "prefix", name: "iad-public"})

      assert {:ok, %Prefix{} = prefix} =
               Inventory.create_prefix(scope, resource.id, %{
                 prefix: "192.0.2.0/24",
                 vrf: "default",
                 description: "Public service network"
               })

      assert prefix.prefix == %Postgrex.INET{address: {192, 0, 2, 0}, netmask: 24}
    end

    test "rejects CIDR values with host bits set" do
      %{scope: scope} = scoped_organizations()
      {:ok, resource} = Inventory.create_resource(scope, %{kind: "prefix", name: "invalid"})

      assert {:error, changeset} =
               Inventory.create_prefix(scope, resource.id, %{prefix: "192.0.2.10/24"})

      assert %{prefix: ["is invalid"]} = errors_on(changeset)
    end

    test "uses PostgreSQL native network types and CIDR operators" do
      %{scope: scope} = scoped_organizations()
      {:ok, resource} = Inventory.create_resource(scope, %{kind: "prefix", name: "iad-public"})
      {:ok, prefix} = Inventory.create_prefix(scope, resource.id, %{prefix: "192.0.2.0/24"})

      assert %{rows: [["macaddr", "inet", "cidr"]]} =
               Repo.query!("""
               SELECT
                 (SELECT udt_name FROM information_schema.columns
                  WHERE table_name = 'interfaces' AND column_name = 'mac_address'),
                 (SELECT udt_name FROM information_schema.columns
                  WHERE table_name = 'addresses' AND column_name = 'address'),
                 (SELECT udt_name FROM information_schema.columns
                  WHERE table_name = 'prefixes' AND column_name = 'prefix')
               """)

      assert %{rows: [[true, false, true]]} =
               Repo.query!(
                 """
                 SELECT
                   prefix >>= $1::text::inet,
                   prefix >>= $2::text::inet,
                   prefix && $3::text::cidr
                 FROM prefixes
                 WHERE id = $4::text::uuid
                 """,
                 ["192.0.2.42", "198.51.100.1", "192.0.2.128/25", prefix.id]
               )

      assert %{rows: [[index_definition]]} =
               Repo.query!("""
               SELECT indexdef
               FROM pg_indexes
               WHERE indexname = 'prefixes_prefix_gist_index'
               """)

      assert index_definition =~ "USING gist (prefix inet_ops)"
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
      source: source,
      sync_run: sync_run
    } do
      assert {:ok, %Observation{} = observation} =
               Inventory.create_observation(scope, source.id, %{
                 sync_run_id: sync_run.id,
                 observation_id: " host-agent:compute-01 ",
                 payload: %{"hostname" => "compute-01", "serial" => "ABC123"}
               })

      assert observation.organization_id == scope.organization_id
      assert observation.source_id == source.id
      assert observation.sync_run_id == sync_run.id
      assert String.at(observation.id, 14) == "7"
      assert observation.idempotency_key == "host-agent:compute-01"
      assert is_binary(observation.payload_digest)
      refute Map.has_key?(observation, :updated_at)

      {:ok, <<uuid_unix_ms::48, _rest::binary>>} = Ecto.UUID.dump(observation.id)
      assert observation.inserted_at == Renga.Time.from_unix_ms!(uuid_unix_ms)
    end

    test "list_observations/1 is scoped by organization", %{
      scope: scope,
      other_scope: other_scope,
      source: source
    } do
      {:ok, observation} =
        Inventory.create_observation(scope, source.id, %{
          observation_id: "host-agent:compute-01",
          payload: %{"hostname" => "compute-01"}
        })

      assert Inventory.list_observations(scope) == [observation]
      assert Inventory.list_observations(other_scope) == []
    end

    test "idempotency is source-keyed while identical later reports remain valid", %{
      scope: scope,
      source: source
    } do
      attrs = %{
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

      assert {:ok, repeated_report} =
               Inventory.create_observation(scope, source.id, %{
                 observation_id: "host-agent:compute-01:next",
                 payload: %{"hostname" => "compute-01"}
               })

      assert repeated_report.idempotency_key == "host-agent:compute-01:next"
    end

    test "the same idempotency key is independent for sources in one organization", %{
      scope: scope,
      source: source
    } do
      {:ok, second_source} =
        Inventory.create_source(scope, %{kind: "host_agent", name: "compute-02-agent"})

      attrs = %{
        observation_id: "shared-report-id",
        payload: %{"hostname" => "compute-01"}
      }

      assert {:ok, first} = Inventory.create_observation(scope, source.id, attrs)
      assert {:ok, second} = Inventory.create_observation(scope, second_source.id, attrs)
      refute first.id == second.id
      assert first.idempotency_key == second.idempotency_key
    end

    test "concurrent retries converge on one observation", %{scope: scope, source: source} do
      attrs = %{
        observation_id: "concurrent-report-id",
        payload: %{"hostname" => "compute-01"}
      }

      tasks =
        for _attempt <- 1..4 do
          Task.async(fn ->
            receive do
              :accept -> Inventory.accept_observation(scope, source.id, attrs)
            end
          end)
        end

      Enum.each(tasks, fn task ->
        Ecto.Adapters.SQL.Sandbox.allow(Repo, self(), task.pid)
        send(task.pid, :accept)
      end)

      results = Task.await_many(tasks)

      assert Enum.count(results, &match?({:ok, _observation, :created}, &1)) == 1
      assert Enum.count(results, &match?({:ok, _observation, :duplicate}, &1)) == 3

      observation_ids =
        Enum.map(results, fn {:ok, observation, _disposition} -> observation.id end)

      assert observation_ids |> Enum.uniq() |> length() == 1

      assert Repo.aggregate(
               from(observation in Observation,
                 where:
                   observation.source_id == ^source.id and
                     observation.idempotency_key == "concurrent-report-id"
               ),
               :count
             ) == 1
    end

    test "raw observations reject updates and processing is stored separately", %{
      scope: scope,
      resource: resource,
      source: source
    } do
      {:ok, observation} =
        Inventory.create_observation(scope, source.id, %{
          observation_id: "host-agent:compute-01",
          payload: %{"hostname" => "compute-01"}
        })

      assert {:error, changeset} =
               observation
               |> Observation.changeset(%{payload: %{"hostname" => "changed"}})
               |> Repo.update()

      assert %{base: ["observation is immutable"]} = errors_on(changeset)

      assert {:ok, %ObservationReconciliation{} = result} =
               Inventory.create_observation_reconciliation(scope, observation.id, %{
                 attempt: 1,
                 status: "succeeded",
                 matched_resource_id: resource.id,
                 completed_at: Renga.Time.utc_now_ms()
               })

      assert result.matched_resource_id == resource.id
      assert Inventory.list_observation_reconciliations(scope, observation.id) == [result]
    end

    test "reconciliation retries preserve every attempt and leave raw evidence unchanged", %{
      scope: scope,
      resource: resource,
      source: source
    } do
      payload = %{"hostname" => "compute-01", "serial_number" => "ABC123"}

      {:ok, observation} =
        Inventory.create_observation(scope, source.id, %{
          observation_id: "host-agent:compute-01",
          payload: payload
        })

      assert {:ok, failed} =
               Inventory.create_observation_reconciliation(scope, observation.id, %{
                 attempt: 1,
                 status: "failed",
                 errors: %{"matcher" => ["ambiguous identity"]},
                 completed_at: ~U[2026-08-03 12:00:00.000000Z]
               })

      assert {:ok, succeeded} =
               Inventory.create_observation_reconciliation(scope, observation.id, %{
                 attempt: 2,
                 status: "succeeded",
                 matched_resource_id: resource.id,
                 completed_at: ~U[2026-08-03 12:01:00.000000Z]
               })

      assert Inventory.list_observation_reconciliations(scope, observation.id) == [
               failed,
               succeeded
             ]

      persisted = Repo.get!(Observation, observation.id)
      assert persisted.payload == payload
      assert persisted.payload_digest == observation.payload_digest
      refute Map.has_key?(persisted, :status)
      refute Map.has_key?(persisted, :resource_id)
    end

    test "PostgreSQL rejects observation updates that bypass the changeset", %{
      scope: scope,
      source: source
    } do
      {:ok, observation} =
        Inventory.create_observation(scope, source.id, %{
          observation_id: "host-agent:compute-01",
          payload: %{"hostname" => "compute-01"}
        })

      assert_raise Postgrex.Error, ~r/observations are immutable/, fn ->
        Observation
        |> where([stored], stored.id == ^observation.id)
        |> Repo.update_all(set: [payload: %{"hostname" => "tampered"}])
      end
    end

    test "deleting a sync run preserves its immutable observations", %{
      scope: scope,
      source: source,
      sync_run: sync_run
    } do
      {:ok, observation} =
        Inventory.create_observation(scope, source.id, %{
          sync_run_id: sync_run.id,
          observation_id: "host-agent:sync-run-deletion",
          payload: %{"hostname" => "compute-01"}
        })

      assert {:ok, _sync_run} = Repo.delete(sync_run)
      assert Repo.get!(Observation, observation.id).sync_run_id == nil
    end

    test "create_change_event/2 records scoped audit entries", %{
      scope: scope,
      resource: resource,
      source: source,
      sync_run: sync_run
    } do
      {:ok, observation} =
        Inventory.create_observation(scope, source.id, %{
          sync_run_id: sync_run.id,
          observation_id: "host-agent:compute-01",
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
