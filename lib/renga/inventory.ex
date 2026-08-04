defmodule Renga.Inventory do
  @moduledoc """
  Inventory source and resource management.

  The inventory context owns organization-scoped sources now and will absorb
  observations, reconciliation, and freshness state in later phases.
  """

  import Ecto.Query, warn: false

  alias Renga.Accounts.Scope
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
  alias Renga.Repo

  @source_token_prefix "renga_src_"
  @source_token_bytes 32
  @resource_revision_lock_key 1_380_271_687

  @doc """
  Lists sources visible inside the caller's organization scope.
  """
  def list_sources(%Scope{organization_id: organization_id}) do
    Source
    |> where([source], source.organization_id == ^organization_id)
    |> order_by([source], asc: source.name)
    |> Repo.all()
  end

  @doc """
  Fetches a source only when it belongs to the caller's organization scope.
  """
  def get_source!(%Scope{organization_id: organization_id}, id) do
    Source
    |> where([source], source.organization_id == ^organization_id)
    |> Repo.get!(id)
  end

  @doc """
  Creates a source without issuing a token.

  Use this for manual/non-agent sources or setup flows that will rotate a token
  separately.
  """
  def create_source(%Scope{organization_id: organization_id}, attrs) do
    %Source{organization_id: organization_id}
    |> Source.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Creates a source and returns its one-time plaintext token.

  The database stores only the token hash; callers must show or persist the
  returned token immediately because it cannot be reconstructed later.
  """
  def create_source_with_token(%Scope{organization_id: organization_id}, attrs) do
    token = generate_source_token()

    result =
      %Source{organization_id: organization_id}
      |> Source.changeset(attrs)
      |> Ecto.Changeset.put_change(:token_hash, hash_source_token(token))
      |> Repo.insert()

    case result do
      {:ok, source} -> {:ok, {source, token}}
      {:error, changeset} -> {:error, changeset}
    end
  end

  @doc """
  Updates source metadata while keeping token lifecycle separate.
  """
  def update_source(%Source{} = source, attrs) do
    source
    |> Source.changeset(attrs)
    |> Repo.update()
  end

  @doc """
  Builds a source changeset for UI/API validation.
  """
  def change_source(%Source{} = source, attrs \\ %{}) do
    Source.changeset(source, attrs)
  end

  @doc """
  Replaces a source token and returns the new one-time plaintext value.
  """
  def rotate_source_token(%Scope{} = scope, source_id) do
    source = get_source!(scope, source_id)
    token = generate_source_token()

    result =
      source
      |> Source.token_changeset(hash_source_token(token))
      |> Repo.update()

    case result do
      {:ok, source} -> {:ok, {source, token}}
      {:error, changeset} -> {:error, changeset}
    end
  end

  @doc """
  Revokes source token authentication without deleting source provenance.
  """
  def revoke_source_token(%Scope{} = scope, source_id) do
    scope
    |> get_source!(source_id)
    |> Source.revoke_changeset()
    |> Repo.update()
  end

  @doc """
  Authenticates a bearer token from an inventory source.

  A valid token identifies one active source and its organization. User auth is
  deliberately separate from source auth because agents are not humans.
  """
  def authenticate_source_token(@source_token_prefix <> _rest = token) do
    token_hash = hash_source_token(token)

    Source
    |> join(:inner, [source], organization in assoc(source, :organization))
    |> where([source], source.token_hash == ^token_hash)
    |> where([source, organization], source.status == "active")
    |> where([source, organization], organization.status == "active")
    |> preload([source, organization], organization: organization)
    |> Repo.one()
    |> case do
      %Source{} = source -> {:ok, source}
      nil -> :error
    end
  end

  def authenticate_source_token(_token), do: :error

  @doc """
  Registers or refreshes an agent and renews its independent liveness lease.

  The source remains a credential/provenance record. Server time determines
  lease liveness so a client clock cannot extend its own connection state.
  """
  def record_agent_check_in(
        %Scope{organization_id: organization_id} = scope,
        source_id,
        attrs \\ %{}
      ) do
    source = get_source!(scope, source_id)
    now = Renga.Time.utc_now_ms()
    agent_attrs = agent_registration_attrs(source, attrs, now)

    Repo.transaction(fn ->
      agent = upsert_agent!(organization_id, source.id, agent_attrs)
      lease = put_agent_lease!(organization_id, agent.id, now, 90_000)
      {agent, lease}
    end)
  end

  @doc """
  Fetches a registered agent through the caller's organization scope.
  """
  def get_agent!(%Scope{organization_id: organization_id}, id) do
    Agent
    |> where([agent], agent.organization_id == ^organization_id)
    |> Repo.get!(id)
  end

  @doc """
  Renews an agent lease using server time or an explicit test/replay timestamp.
  """
  def renew_agent_lease(%Scope{organization_id: organization_id} = scope, agent_id, attrs \\ %{}) do
    agent = get_agent!(scope, agent_id)

    renewed_at =
      Map.get(attrs, :renewed_at) || Map.get(attrs, "renewed_at") || Renga.Time.utc_now_ms()

    ttl_ms = Map.get(attrs, :ttl_ms) || Map.get(attrs, "ttl_ms") || 90_000

    put_agent_lease(organization_id, agent.id, renewed_at, ttl_ms)
  end

  @doc """
  Fetches the current renewable lease for a scoped agent.
  """
  def get_agent_lease!(%Scope{organization_id: organization_id}, agent_id) do
    AgentLease
    |> where([lease], lease.organization_id == ^organization_id)
    |> where([lease], lease.agent_id == ^agent_id)
    |> Repo.one!()
  end

  @doc """
  Lists canonical resources visible inside the caller's organization scope.
  """
  def list_resources(%Scope{organization_id: organization_id}) do
    Resource
    |> where([resource], resource.organization_id == ^organization_id)
    |> order_by([resource], asc: resource.name, asc: resource.id)
    |> Repo.all()
  end

  @doc """
  Fetches a resource only when it belongs to the caller's organization scope.
  """
  def get_resource!(%Scope{organization_id: organization_id}, id) do
    Resource
    |> where([resource], resource.organization_id == ^organization_id)
    |> Repo.get!(id)
  end

  @doc """
  Creates a canonical resource within the caller's organization.

  `organization_id` is assigned from the trusted scope so callers cannot create
  resources in another tenant by passing forged attrs.
  """
  def create_resource(%Scope{organization_id: organization_id}, attrs) do
    Repo.transaction(fn ->
      revision = next_resource_revision!()

      resource =
        %Resource{organization_id: organization_id}
        |> Resource.changeset(attrs)
        |> Ecto.Changeset.put_change(:resource_version, revision)
        |> insert_or_rollback()

      insert_resource_revision!(resource, revision, "created")
      resource
    end)
  end

  @doc """
  Updates canonical resource fields within the caller's organization scope.
  """
  def update_resource(
        %Scope{organization_id: organization_id},
        %Resource{} = resource,
        attrs
      ) do
    Repo.transaction(fn ->
      stored_resource =
        Resource
        |> where([stored], stored.id == ^resource.id)
        |> where([stored], stored.organization_id == ^organization_id)
        |> lock("FOR UPDATE")
        |> Repo.one!()

      revision = next_resource_revision!()

      resource =
        stored_resource
        |> Resource.changeset(attrs)
        |> Ecto.Changeset.put_change(:resource_version, revision)
        |> update_or_rollback()

      insert_resource_revision!(
        resource,
        revision,
        revision_action(stored_resource, resource)
      )

      resource
    end)
  end

  @doc """
  Builds a resource changeset for UI/API validation.
  """
  def change_resource(%Resource{} = resource, attrs \\ %{}) do
    Resource.changeset(resource, attrs)
  end

  @doc """
  Creates the typed host projection for a server-like resource.

  The projection is source-neutral current state. Host observations and their
  provenance are retained separately and reconciled into this row later.
  """
  def create_host(%Scope{organization_id: organization_id} = scope, resource_id, attrs) do
    resource = get_resource!(scope, resource_id)

    %Host{organization_id: organization_id, resource_id: resource.id}
    |> Host.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Fetches a typed host projection through its resource tenant boundary.
  """
  def get_host_by_resource!(%Scope{organization_id: organization_id}, resource_id) do
    Host
    |> where([host], host.organization_id == ^organization_id)
    |> where([host], host.resource_id == ^resource_id)
    |> Repo.one!()
  end

  @doc """
  Lists current conditions for a scoped resource.
  """
  def list_resource_conditions(%Scope{organization_id: organization_id}, resource_id) do
    ResourceCondition
    |> where([condition], condition.organization_id == ^organization_id)
    |> where([condition], condition.resource_id == ^resource_id)
    |> order_by([condition], asc: condition.type)
    |> Repo.all()
  end

  @doc """
  Creates or transitions one independent resource condition.

  `last_transition_at` advances only when status changes. Reason and message can
  still be refreshed without making a stable condition appear newly changed.
  """
  def put_resource_condition(%Scope{organization_id: organization_id} = scope, resource_id, attrs) do
    resource = get_resource!(scope, resource_id)
    type = Map.get(attrs, :type) || Map.get(attrs, "type")

    existing =
      Repo.get_by(ResourceCondition,
        organization_id: organization_id,
        resource_id: resource.id,
        type: type
      )

    transition_at = condition_transition_at(existing, attrs)
    attrs = put_condition_transition_at(attrs, transition_at)

    (existing ||
       %ResourceCondition{
         organization_id: organization_id,
         resource_id: resource.id
       })
    |> ResourceCondition.changeset(attrs)
    |> Repo.insert_or_update()
  end

  @doc """
  Lists ordered revisions for a scoped resource.
  """
  def list_resource_revisions(%Scope{organization_id: organization_id}, resource_id) do
    ResourceRevision
    |> where([revision], revision.organization_id == ^organization_id)
    |> where([revision], revision.resource_id == ^resource_id)
    |> order_by([revision], asc: revision.revision)
    |> Repo.all()
  end

  @doc """
  Lists canonical identifiers for a resource in the caller's organization.
  """
  def list_resource_identifiers(%Scope{organization_id: organization_id}, resource_id) do
    ResourceIdentifier
    |> where([identifier], identifier.organization_id == ^organization_id)
    |> where([identifier], identifier.resource_id == ^resource_id)
    |> order_by([identifier], asc: identifier.kind, asc: identifier.value)
    |> Repo.all()
  end

  @doc """
  Adds a source-neutral canonical identifier to a resource.

  The organization id is copied from the caller scope and the resource must be
  fetched through the same scope before this function is called.
  """
  def create_resource_identifier(
        %Scope{organization_id: organization_id} = scope,
        resource_id,
        attrs
      ) do
    resource = get_resource!(scope, resource_id)

    %ResourceIdentifier{
      organization_id: organization_id,
      resource_id: resource.id
    }
    |> ResourceIdentifier.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Lists source claims for one canonical resource, including conflicting values.
  """
  def list_resource_identifier_claims(
        %Scope{organization_id: organization_id},
        resource_id
      ) do
    ResourceIdentifierClaim
    |> where([claim], claim.organization_id == ^organization_id)
    |> where([claim], claim.resource_id == ^resource_id)
    |> order_by([claim], asc: claim.kind, asc: claim.normalized_value, asc: claim.inserted_at)
    |> Repo.all()
  end

  @doc """
  Stores one observation-scoped source assertion about identity.

  Canonical links are optional because unresolved and conflicting claims must be
  representable before the reconciler chooses a resource.
  """
  def create_resource_identifier_claim(
        %Scope{organization_id: organization_id} = scope,
        source_id,
        observation_id,
        attrs
      ) do
    source = get_source!(scope, source_id)
    observation = get_source_observation!(scope, source.id, observation_id)

    attrs =
      attrs
      |> put_new_attr(:first_seen_at, observation.observed_at)
      |> put_new_attr(:last_seen_at, observation.observed_at)

    resource =
      case get_attr(attrs, :resource_id) do
        nil -> nil
        id -> get_resource!(scope, id)
      end

    resource_identifier =
      case get_attr(attrs, :resource_identifier_id) do
        nil -> nil
        id -> get_resource_identifier!(scope, id)
      end

    resource_id =
      case {resource, resource_identifier} do
        {%Resource{id: id}, _resource_identifier} -> id
        {nil, %ResourceIdentifier{resource_id: id}} -> id
        {nil, nil} -> nil
      end

    %ResourceIdentifierClaim{
      organization_id: organization_id,
      source_id: source.id,
      observation_id: observation.id,
      resource_id: resource_id,
      resource_identifier_id: resource_identifier && resource_identifier.id
    }
    |> ResourceIdentifierClaim.changeset(attrs)
    |> validate_claim_resource_link(resource, resource_identifier)
    |> Repo.insert()
  end

  @doc """
  Lists interfaces for a resource in the caller's organization scope.
  """
  def list_interfaces(%Scope{organization_id: organization_id}, resource_id) do
    Interface
    |> where([interface], interface.organization_id == ^organization_id)
    |> where([interface], interface.resource_id == ^resource_id)
    |> order_by([interface], asc: interface.name)
    |> Repo.all()
  end

  @doc """
  Fetches an interface only when it belongs to the caller's organization scope.
  """
  def get_interface!(%Scope{organization_id: organization_id}, id) do
    Interface
    |> where([interface], interface.organization_id == ^organization_id)
    |> Repo.get!(id)
  end

  @doc """
  Creates an interface under a scoped resource.
  """
  def create_interface(%Scope{organization_id: organization_id} = scope, resource_id, attrs) do
    resource = get_resource!(scope, resource_id)

    %Interface{
      organization_id: organization_id,
      resource_id: resource.id
    }
    |> Interface.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Lists addresses for a resource interface in the caller's organization scope.
  """
  def list_addresses(%Scope{organization_id: organization_id}, interface_id) do
    Address
    |> where([address], address.organization_id == ^organization_id)
    |> where([address], address.interface_id == ^interface_id)
    |> order_by([address], asc: address.address)
    |> Repo.all()
  end

  @doc """
  Creates an address under a scoped interface.

  `resource_id` is copied from the interface to keep resource-level address
  queries cheap and consistently organization-scoped.
  """
  def create_address(%Scope{organization_id: organization_id} = scope, interface_id, attrs) do
    interface = get_interface!(scope, interface_id)

    %Address{
      organization_id: organization_id,
      resource_id: interface.resource_id,
      interface_id: interface.id
    }
    |> Address.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Lists relationships touching a scoped interface.
  """
  def list_interface_relationships(%Scope{organization_id: organization_id}, interface_id) do
    InterfaceRelationship
    |> where([relationship], relationship.organization_id == ^organization_id)
    |> where(
      [relationship],
      relationship.source_interface_id == ^interface_id or
        relationship.target_interface_id == ^interface_id
    )
    |> order_by([relationship], asc: relationship.kind, asc: relationship.id)
    |> Repo.all()
  end

  @doc """
  Creates a directed relationship between two scoped interfaces.

  The relationship source and target must both belong to the caller's
  organization. Collector provenance is stored in relationship evidence.
  """
  def create_interface_relationship(
        %Scope{organization_id: organization_id} = scope,
        source_interface_id,
        target_interface_id,
        attrs
      ) do
    source_interface = get_interface!(scope, source_interface_id)
    target_interface = get_interface!(scope, target_interface_id)

    %InterfaceRelationship{
      organization_id: organization_id,
      source_interface_id: source_interface.id,
      target_interface_id: target_interface.id
    }
    |> InterfaceRelationship.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Creates a typed canonical IPAM prefix for a resource envelope.
  """
  def create_prefix(%Scope{organization_id: organization_id} = scope, resource_id, attrs) do
    resource = get_resource!(scope, resource_id)

    %Prefix{organization_id: organization_id, resource_id: resource.id}
    |> Prefix.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Stores one source observation of a canonical interface.
  """
  def create_interface_evidence(
        %Scope{organization_id: organization_id} = scope,
        source_id,
        observation_id,
        interface_id,
        attrs
      ) do
    {source, observation} = source_observation!(scope, source_id, observation_id)
    interface = get_interface!(scope, interface_id)
    attrs = put_new_attr(attrs, :observed_at, observation.observed_at)

    %InterfaceEvidence{
      organization_id: organization_id,
      source_id: source.id,
      observation_id: observation.id,
      interface_id: interface.id
    }
    |> InterfaceEvidence.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Stores one source observation of a canonical assigned address.
  """
  def create_address_evidence(
        %Scope{organization_id: organization_id} = scope,
        source_id,
        observation_id,
        address_id,
        attrs
      ) do
    {source, observation} = source_observation!(scope, source_id, observation_id)
    address = get_address!(scope, address_id)
    attrs = put_new_attr(attrs, :observed_at, observation.observed_at)

    %AddressEvidence{
      organization_id: organization_id,
      source_id: source.id,
      observation_id: observation.id,
      address_id: address.id
    }
    |> AddressEvidence.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Stores one source observation of a canonical interface relationship.
  """
  def create_interface_relationship_evidence(
        %Scope{organization_id: organization_id} = scope,
        source_id,
        observation_id,
        relationship_id,
        attrs
      ) do
    {source, observation} = source_observation!(scope, source_id, observation_id)
    relationship = get_interface_relationship!(scope, relationship_id)
    attrs = put_new_attr(attrs, :observed_at, observation.observed_at)

    %InterfaceRelationshipEvidence{
      organization_id: organization_id,
      source_id: source.id,
      observation_id: observation.id,
      interface_relationship_id: relationship.id
    }
    |> InterfaceRelationshipEvidence.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Creates a cross-domain topology link when no typed relationship table applies.
  """
  def create_resource_relationship(
        %Scope{organization_id: organization_id} = scope,
        source_resource_id,
        target_resource_id,
        attrs
      ) do
    source_resource = get_resource!(scope, source_resource_id)
    target_resource = get_resource!(scope, target_resource_id)

    %ResourceRelationship{
      organization_id: organization_id,
      source_resource_id: source_resource.id,
      target_resource_id: target_resource.id
    }
    |> ResourceRelationship.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Creates lifecycle ownership separately from descriptive topology.
  """
  def create_resource_owner(
        %Scope{organization_id: organization_id} = scope,
        owner_resource_id,
        child_resource_id,
        attrs
      ) do
    owner_resource = get_resource!(scope, owner_resource_id)
    child_resource = get_resource!(scope, child_resource_id)

    %ResourceOwner{
      organization_id: organization_id,
      owner_resource_id: owner_resource.id,
      child_resource_id: child_resource.id
    }
    |> ResourceOwner.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Lists lifecycle owners for a scoped child resource.
  """
  def list_resource_owners(%Scope{organization_id: organization_id}, child_resource_id) do
    ResourceOwner
    |> where([owner], owner.organization_id == ^organization_id)
    |> where([owner], owner.child_resource_id == ^child_resource_id)
    |> order_by([owner], desc: owner.controller, asc: owner.inserted_at)
    |> Repo.all()
  end

  @doc """
  Lists sync runs visible inside the caller's organization scope.
  """
  def list_sync_runs(%Scope{organization_id: organization_id}) do
    SyncRun
    |> where([sync_run], sync_run.organization_id == ^organization_id)
    |> order_by([sync_run], desc: sync_run.started_at)
    |> Repo.all()
  end

  @doc """
  Fetches a sync run only when it belongs to the caller's organization scope.
  """
  def get_sync_run!(%Scope{organization_id: organization_id}, id) do
    SyncRun
    |> where([sync_run], sync_run.organization_id == ^organization_id)
    |> Repo.get!(id)
  end

  @doc """
  Creates an ingestion run for a scoped source.

  `started_at` defaults here so callers can open a run without each source
  adapter repeating timestamp boilerplate.
  """
  def create_sync_run(%Scope{organization_id: organization_id} = scope, source_id, attrs \\ %{}) do
    source = get_source!(scope, source_id)

    attrs =
      attrs
      |> Map.put_new(:started_at, Renga.Time.utc_now_ms())

    %SyncRun{
      organization_id: organization_id,
      source_id: source.id
    }
    |> SyncRun.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Lists immutable raw observations in the caller's organization, newest first.
  """
  def list_observations(%Scope{organization_id: organization_id}) do
    Observation
    |> where([observation], observation.organization_id == ^organization_id)
    |> order_by([observation], desc: observation.observed_at)
    |> Repo.all()
  end

  @doc """
  Stores one raw source payload.

  The payload digest is computed when absent so duplicate submissions can be
  rejected without requiring every collector to pre-hash its own payload.
  """
  def create_observation(%Scope{organization_id: organization_id} = scope, source_id, attrs) do
    source = get_source!(scope, source_id)
    attrs = normalize_observation_attrs(scope, attrs)

    %Observation{
      organization_id: organization_id,
      source_id: source.id,
      sync_run_id: Map.get(attrs, :sync_run_id) || Map.get(attrs, "sync_run_id")
    }
    |> Observation.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Stores one raw source payload with idempotent duplicate handling.

  A source-provided observation id protects agent retry loops from creating
  duplicates. When that id is absent, the payload digest provides the same
  retry behavior for byte-equivalent JSON payloads decoded by Phoenix.
  """
  def accept_observation(%Scope{} = scope, source_id, attrs) do
    source = get_source!(scope, source_id)
    attrs = normalize_observation_attrs(scope, attrs)
    idempotency_key = Map.get(attrs, :idempotency_key) || Map.get(attrs, "idempotency_key")
    payload_digest = Map.get(attrs, :payload_digest) || Map.get(attrs, "payload_digest")

    case find_idempotent_observation(scope, source.id, idempotency_key) do
      %Observation{} = observation ->
        idempotent_observation_result(observation, payload_digest)

      nil ->
        insert_idempotent_observation(scope, source.id, attrs, idempotency_key, payload_digest)
    end
  end

  @doc """
  Records a scoped reconciliation attempt without mutating raw evidence.
  """
  def create_observation_reconciliation(
        %Scope{organization_id: organization_id} = scope,
        observation_id,
        attrs
      ) do
    observation = get_observation!(scope, observation_id)
    attrs = normalize_scoped_assoc(attrs, scope, :matched_resource_id, &get_resource!/2)

    %ObservationReconciliation{
      organization_id: organization_id,
      observation_id: observation.id,
      matched_resource_id:
        Map.get(attrs, :matched_resource_id) || Map.get(attrs, "matched_resource_id")
    }
    |> ObservationReconciliation.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Lists processing attempts for one scoped observation in attempt order.
  """
  def list_observation_reconciliations(
        %Scope{organization_id: organization_id},
        observation_id
      ) do
    ObservationReconciliation
    |> where([result], result.organization_id == ^organization_id)
    |> where([result], result.observation_id == ^observation_id)
    |> order_by([result], asc: result.attempt)
    |> Repo.all()
  end

  @doc """
  Lists audit events for a scoped resource, newest first.
  """
  def list_change_events(%Scope{organization_id: organization_id}, resource_id) do
    ChangeEvent
    |> where([event], event.organization_id == ^organization_id)
    |> where([event], event.resource_id == ^resource_id)
    |> order_by([event], desc: event.occurred_at)
    |> Repo.all()
  end

  @doc """
  Records a resource or observation state transition.

  Optional linked ids are resolved through the caller scope before insertion so
  audit trails cannot silently join rows from another organization.
  """
  def create_change_event(%Scope{organization_id: organization_id} = scope, attrs) do
    attrs = normalize_change_event_attrs(scope, attrs)

    %ChangeEvent{
      organization_id: organization_id,
      source_id: Map.get(attrs, :source_id) || Map.get(attrs, "source_id"),
      resource_id: Map.get(attrs, :resource_id) || Map.get(attrs, "resource_id"),
      sync_run_id: Map.get(attrs, :sync_run_id) || Map.get(attrs, "sync_run_id"),
      observation_id: Map.get(attrs, :observation_id) || Map.get(attrs, "observation_id")
    }
    |> ChangeEvent.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Marks the resource inventory condition stale inside the caller's organization.

  Freshness is independent from lifecycle: an active resource can have stale
  inventory without becoming inactive or retired.
  """
  def mark_resource_stale(
        %Scope{} = scope,
        resource_id,
        stale_at \\ Renga.Time.utc_now_ms()
      ) do
    resource = get_resource!(scope, resource_id)

    put_resource_condition(scope, resource.id, %{
      type: "InventoryCurrent",
      status: "false",
      reason: "Stale",
      message: "No current inventory observation is available",
      observed_generation: resource.generation,
      last_transition_at: stale_at
    })
  end

  @doc """
  Lists manual overrides for a scoped resource.
  """
  def list_resource_overrides(%Scope{organization_id: organization_id}, resource_id) do
    ResourceOverride
    |> where([override], override.organization_id == ^organization_id)
    |> where([override], override.resource_id == ^resource_id)
    |> order_by([override], asc: override.field)
    |> Repo.all()
  end

  @doc """
  Creates a field-level manual override for a scoped resource.

  `created_by_user_id` is copied from the scope when present so callers cannot
  impersonate a different human actor through attrs.
  """
  def create_resource_override(
        %Scope{organization_id: organization_id} = scope,
        resource_id,
        attrs
      ) do
    resource = get_resource!(scope, resource_id)

    %ResourceOverride{
      organization_id: organization_id,
      resource_id: resource.id,
      created_by_user_id: scope.user && scope.user.id
    }
    |> ResourceOverride.changeset(attrs)
    |> Repo.insert()
  end

  defp generate_source_token do
    @source_token_prefix <>
      Base.url_encode64(:crypto.strong_rand_bytes(@source_token_bytes), padding: false)
  end

  # SHA-256 is sufficient here because source tokens are high-entropy random
  # secrets, unlike user passwords that need slow Argon2 hashing.
  defp hash_source_token(token), do: :crypto.hash(:sha256, token)

  defp next_resource_revision! do
    # Hold allocation order until commit so a watch cursor cannot pass an
    # earlier revision that is still invisible in another transaction.
    Repo.query!("SELECT pg_advisory_xact_lock($1)", [@resource_revision_lock_key])
    %{rows: [[revision]]} = Repo.query!("SELECT nextval('resource_revision_sequence')")
    revision
  end

  defp insert_resource_revision!(resource, revision, action) do
    %ResourceRevision{
      organization_id: resource.organization_id,
      resource_id: resource.id
    }
    |> ResourceRevision.changeset(%{
      revision: revision,
      action: action,
      generation: resource.generation,
      snapshot: resource_snapshot(resource)
    })
    |> Repo.insert!()
  end

  defp resource_snapshot(resource) do
    %{
      "id" => resource.id,
      "kind" => resource.kind,
      "name" => resource.name,
      "display_name" => resource.display_name,
      "lifecycle_state" => resource.lifecycle_state,
      "spec" => resource.spec,
      "generation" => resource.generation,
      "resource_version" => resource.resource_version,
      "labels" => resource.labels,
      "annotations" => resource.annotations
    }
  end

  defp revision_action(
         %Resource{deletion_requested_at: nil},
         %Resource{deletion_requested_at: deletion_requested_at}
       )
       when not is_nil(deletion_requested_at),
       do: "deletion_requested"

  defp revision_action(%Resource{}, %Resource{}), do: "updated"

  defp insert_or_rollback(changeset) do
    case Repo.insert(changeset) do
      {:ok, record} -> record
      {:error, changeset} -> Repo.rollback(changeset)
    end
  end

  defp update_or_rollback(changeset) do
    case Repo.update(changeset) do
      {:ok, record} -> record
      {:error, changeset} -> Repo.rollback(changeset)
    end
  end

  defp agent_registration_attrs(source, attrs, now) do
    metadata = get_attr(attrs, :metadata)

    %{
      name: get_attr(attrs, :name) || source.name,
      registered_at: now
    }
    |> maybe_put(:version, get_attr(attrs, :version) || metadata_version(metadata))
    |> maybe_put(:capabilities, get_attr(attrs, :capabilities))
    |> maybe_put(:metadata, metadata)
  end

  defp upsert_agent!(organization_id, source_id, attrs) do
    update_version? = Map.has_key?(attrs, :version)
    update_capabilities? = Map.has_key?(attrs, :capabilities)
    merge_metadata? = Map.has_key?(attrs, :metadata)

    on_conflict =
      from(agent in Agent,
        update: [
          set: [
            version:
              fragment(
                "CASE WHEN ? THEN EXCLUDED.version ELSE ? END",
                ^update_version?,
                agent.version
              ),
            capabilities:
              fragment(
                "CASE WHEN ? THEN EXCLUDED.capabilities ELSE ? END",
                ^update_capabilities?,
                agent.capabilities
              ),
            metadata:
              fragment(
                "CASE WHEN ? THEN ? || EXCLUDED.metadata ELSE ? END",
                ^merge_metadata?,
                agent.metadata,
                agent.metadata
              ),
            updated_at: fragment("EXCLUDED.updated_at")
          ]
        ]
      )

    result =
      %Agent{organization_id: organization_id, source_id: source_id}
      |> Agent.changeset(attrs)
      |> Repo.insert(
        on_conflict: on_conflict,
        conflict_target: [:organization_id, :source_id, :name],
        returning: true
      )

    case result do
      {:ok, agent} -> agent
      {:error, changeset} -> Repo.rollback(changeset)
    end
  end

  defp put_agent_lease(organization_id, agent_id, renewed_at, ttl_ms)
       when is_integer(ttl_ms) and ttl_ms > 0 do
    expires_at = DateTime.add(renewed_at, ttl_ms, :millisecond)

    on_conflict =
      from(lease in AgentLease,
        update: [
          set: [
            renewed_at:
              fragment(
                "CASE WHEN EXCLUDED.renewed_at > ? THEN EXCLUDED.renewed_at ELSE ? END",
                lease.renewed_at,
                lease.renewed_at
              ),
            expires_at:
              fragment(
                "CASE WHEN EXCLUDED.renewed_at > ? THEN EXCLUDED.expires_at ELSE ? END",
                lease.renewed_at,
                lease.expires_at
              ),
            updated_at:
              fragment(
                "CASE WHEN EXCLUDED.renewed_at > ? THEN EXCLUDED.updated_at ELSE ? END",
                lease.renewed_at,
                lease.updated_at
              )
          ]
        ]
      )

    %AgentLease{organization_id: organization_id, agent_id: agent_id}
    |> AgentLease.changeset(%{renewed_at: renewed_at, expires_at: expires_at})
    |> Repo.insert(
      on_conflict: on_conflict,
      conflict_target: [:organization_id, :agent_id],
      returning: true
    )
  end

  defp put_agent_lease!(organization_id, agent_id, renewed_at, ttl_ms) do
    case put_agent_lease(organization_id, agent_id, renewed_at, ttl_ms) do
      {:ok, lease} -> lease
      {:error, changeset} -> Repo.rollback(changeset)
    end
  end

  defp metadata_version(metadata) when is_map(metadata), do: Map.get(metadata, "agent_version")
  defp metadata_version(_metadata), do: nil

  defp get_attr(attrs, key), do: Map.get(attrs, key) || Map.get(attrs, Atom.to_string(key))

  defp condition_transition_at(nil, attrs) do
    Map.get(attrs, :last_transition_at) ||
      Map.get(attrs, "last_transition_at") ||
      Renga.Time.utc_now_ms()
  end

  defp condition_transition_at(condition, attrs) do
    status = Map.get(attrs, :status) || Map.get(attrs, "status") || condition.status

    if status == condition.status do
      condition.last_transition_at
    else
      Map.get(attrs, :last_transition_at) ||
        Map.get(attrs, "last_transition_at") ||
        Renga.Time.utc_now_ms()
    end
  end

  defp put_condition_transition_at(attrs, transition_at) do
    if Enum.all?(Map.keys(attrs), &is_binary/1) do
      Map.put(attrs, "last_transition_at", transition_at)
    else
      Map.put(attrs, :last_transition_at, transition_at)
    end
  end

  defp put_new_attr(attrs, key, value) do
    if Enum.all?(Map.keys(attrs), &is_binary/1) do
      Map.put_new(attrs, Atom.to_string(key), value)
    else
      Map.put_new(attrs, key, value)
    end
  end

  defp maybe_put(attrs, _key, nil), do: attrs
  defp maybe_put(attrs, key, value), do: Map.put(attrs, key, value)

  defp normalize_observation_attrs(scope, attrs) do
    payload = Map.get(attrs, :payload) || Map.get(attrs, "payload")

    idempotency_key =
      Map.get(attrs, :idempotency_key) ||
        Map.get(attrs, "idempotency_key") ||
        Map.get(attrs, :observation_id) ||
        Map.get(attrs, "observation_id")

    attrs
    |> Map.put(:idempotency_key, idempotency_key)
    |> Map.put_new(:observed_at, Renga.Time.utc_now_ms())
    |> Map.put_new(:payload_digest, digest_payload(payload))
    |> normalize_scoped_assoc(scope, :sync_run_id, &get_sync_run!/2)
  end

  defp insert_idempotent_observation(scope, source_id, attrs, idempotency_key, payload_digest) do
    case create_observation(scope, source_id, attrs) do
      {:ok, observation} ->
        {:ok, observation, :created}

      {:error, changeset} ->
        case find_idempotent_observation(scope, source_id, idempotency_key) do
          %Observation{} = observation ->
            idempotent_observation_result(observation, payload_digest)

          nil ->
            {:error, changeset}
        end
    end
  end

  defp idempotent_observation_result(%Observation{} = observation, payload_digest) do
    if observation.payload_digest == payload_digest do
      {:ok, observation, :duplicate}
    else
      {:error, :idempotency_conflict, observation}
    end
  end

  defp find_idempotent_observation(
         %Scope{organization_id: organization_id},
         source_id,
         idempotency_key
       ) do
    Repo.get_by(Observation,
      organization_id: organization_id,
      source_id: source_id,
      idempotency_key: idempotency_key
    )
  end

  defp normalize_change_event_attrs(scope, attrs) do
    attrs
    |> Map.put_new(:occurred_at, Renga.Time.utc_now_ms())
    |> normalize_scoped_assoc(scope, :source_id, &get_source!/2)
    |> normalize_scoped_assoc(scope, :resource_id, &get_resource!/2)
    |> normalize_scoped_assoc(scope, :sync_run_id, &get_sync_run!/2)
    |> normalize_scoped_assoc(scope, :observation_id, &get_observation!/2)
  end

  defp normalize_scoped_assoc(attrs, scope, field, fetch_fun) do
    value = Map.get(attrs, field) || Map.get(attrs, Atom.to_string(field))

    if is_nil(value) do
      attrs
    else
      record = fetch_fun.(scope, value)
      put_attr(attrs, field, record.id)
    end
  end

  defp put_attr(attrs, key, value) do
    string_key = Atom.to_string(key)

    if Map.has_key?(attrs, string_key) do
      Map.put(attrs, string_key, value)
    else
      Map.put(attrs, key, value)
    end
  end

  defp validate_claim_resource_link(changeset, resource, resource_identifier) do
    changeset
    |> validate_claim_resource(resource, resource_identifier)
    |> validate_claim_identifier(resource_identifier)
  end

  defp validate_claim_resource(
         changeset,
         %Resource{id: resource_id},
         %ResourceIdentifier{resource_id: identifier_resource_id}
       )
       when resource_id != identifier_resource_id do
    Ecto.Changeset.add_error(changeset, :resource_id, "must match resource identifier")
  end

  defp validate_claim_resource(changeset, _resource, _resource_identifier), do: changeset

  defp validate_claim_identifier(changeset, %ResourceIdentifier{} = resource_identifier) do
    claim_kind = Ecto.Changeset.get_field(changeset, :kind)
    claim_value = Ecto.Changeset.get_field(changeset, :normalized_value)

    if is_binary(claim_kind) and is_binary(claim_value) and
         (claim_kind != resource_identifier.kind or
            claim_value != resource_identifier.normalized_value) do
      Ecto.Changeset.add_error(
        changeset,
        :resource_identifier_id,
        "must match claim kind and normalized value"
      )
    else
      changeset
    end
  end

  defp validate_claim_identifier(changeset, nil), do: changeset

  defp get_observation!(%Scope{organization_id: organization_id}, id) do
    Observation
    |> where([observation], observation.organization_id == ^organization_id)
    |> Repo.get!(id)
  end

  defp get_source_observation!(
         %Scope{organization_id: organization_id},
         source_id,
         observation_id
       ) do
    Observation
    |> where([observation], observation.organization_id == ^organization_id)
    |> where([observation], observation.source_id == ^source_id)
    |> Repo.get!(observation_id)
  end

  defp source_observation!(scope, source_id, observation_id) do
    source = get_source!(scope, source_id)
    {source, get_source_observation!(scope, source.id, observation_id)}
  end

  defp get_address!(%Scope{organization_id: organization_id}, id) do
    Address
    |> where([address], address.organization_id == ^organization_id)
    |> Repo.get!(id)
  end

  defp get_interface_relationship!(%Scope{organization_id: organization_id}, id) do
    InterfaceRelationship
    |> where([relationship], relationship.organization_id == ^organization_id)
    |> Repo.get!(id)
  end

  defp get_resource_identifier!(%Scope{organization_id: organization_id}, id) do
    ResourceIdentifier
    |> where([identifier], identifier.organization_id == ^organization_id)
    |> Repo.get!(id)
  end

  defp digest_payload(nil), do: digest_payload(%{})

  defp digest_payload(payload) do
    payload
    |> :erlang.term_to_binary()
    |> then(&:crypto.hash(:sha256, &1))
  end
end
