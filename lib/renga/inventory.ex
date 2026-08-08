defmodule Renga.Inventory do
  @moduledoc """
  Inventory source and resource management.

  The inventory context owns organization-scoped sources now and will absorb
  observations, reconciliation, and freshness state in later phases.
  """

  import Ecto.Query, warn: false

  alias Renga.Accounts.Organization
  alias Renga.Accounts.Scope
  alias Renga.Inventory.Address
  alias Renga.Inventory.AddressEvidence
  alias Renga.Inventory.Agent
  alias Renga.Inventory.AgentLease
  alias Renga.Inventory.AgentPayload
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
  alias Renga.Inventory.Reconciler
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
  Lists sources with registered agents and leases for operational views.
  """
  def list_operational_sources(%Scope{organization_id: organization_id}) do
    agents_query = from(agent in Agent, order_by: [agent.name, agent.id], preload: [:lease])

    Source
    |> where([source], source.organization_id == ^organization_id)
    |> order_by([source], asc: source.name, asc: source.id)
    |> preload(agents: ^agents_query)
    |> Repo.all()
  end

  @doc """
  Returns the most recently observed resource attributed to each scoped source.

  Host collectors currently bind to one installation, while provenance remains
  general enough for future sources that may report more than one resource.
  """
  def latest_resources_by_source(%Scope{organization_id: organization_id}) do
    ResourceIdentifierClaim
    |> join(:inner, [claim], resource in Resource, on: resource.id == claim.resource_id)
    |> where([claim], claim.organization_id == ^organization_id)
    |> distinct([claim], claim.source_id)
    |> order_by([claim], [claim.source_id, desc: claim.last_seen_at, desc: claim.id])
    |> select([claim, resource], {claim.source_id, resource})
    |> Repo.all()
    |> Map.new()
  end

  @doc """
  Returns each scoped source's latest accepted inventory timestamp.
  """
  def latest_observation_times(%Scope{organization_id: organization_id}) do
    Observation
    |> where([observation], observation.organization_id == ^organization_id)
    |> group_by([observation], observation.source_id)
    |> select([observation], {observation.source_id, max(observation.observed_at)})
    |> Repo.all()
    |> Map.new()
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
  Creates a one-installation host collector for an organization administrator.
  """
  def create_collector_with_token(%Scope{} = scope, attrs) do
    with :ok <- authorize_collector_management(scope) do
      attrs =
        attrs
        |> put_attr(:kind, "host_agent")
        |> put_attr(:status, "active")

      create_source_with_token(scope, attrs)
    end
  end

  @doc """
  Returns whether the current human organization scope can manage collectors.
  """
  def collector_manager?(%Scope{user: user, roles: roles}) do
    not is_nil(user) and Enum.any?(roles, &(&1 in ["owner", "admin"]))
  end

  @doc """
  Updates source metadata while keeping token lifecycle separate.
  """
  def update_source(%Scope{} = scope, %Source{} = source, attrs) do
    scope
    |> get_source!(source.id)
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
  Replaces a host collector credential without changing its installation binding.
  """
  def rotate_collector_token(%Scope{} = scope, source_id) do
    with :ok <- authorize_collector_management(scope),
         {:ok, source} <- fetch_host_collector(scope, source_id) do
      token = generate_source_token()

      case source |> Source.token_changeset(hash_source_token(token)) |> Repo.update() do
        {:ok, source} -> {:ok, {source, token}}
        {:error, changeset} -> {:error, changeset}
      end
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
  Revokes one host collector credential while retaining its provenance.
  """
  def revoke_collector_token(%Scope{} = scope, source_id) do
    with :ok <- authorize_collector_management(scope),
         {:ok, source} <- fetch_host_collector(scope, source_id) do
      source |> Source.revoke_changeset() |> Repo.update()
    end
  end

  @doc """
  Removes a collector's runtime binding and replaces its credential.

  Source provenance and observations remain intact; only the renewable agent
  registration is removed so a new installation can claim the credential.
  """
  def reset_collector_enrollment(
        %Scope{organization_id: organization_id} = scope,
        source_id
      ) do
    with :ok <- authorize_collector_management(scope) do
      token = generate_source_token()

      Repo.transaction(fn ->
        source = lock_host_collector_or_rollback(organization_id, source_id)

        Agent
        |> where([agent], agent.organization_id == ^organization_id)
        |> where([agent], agent.source_id == ^source.id)
        |> Repo.delete_all()

        source =
          source
          |> Source.token_changeset(hash_source_token(token))
          |> update_or_rollback()

        {source, token}
      end)
    end
  end

  defp lock_host_collector_or_rollback(organization_id, source_id) do
    case lock_host_collector(organization_id, source_id) do
      %Source{} = source -> source
      nil -> Repo.rollback(:not_found)
    end
  end

  defp authorize_collector_management(scope) do
    if collector_manager?(scope), do: :ok, else: {:error, :forbidden}
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
    do_record_agent_check_in(organization_id, source, attrs, nil)
  end

  @doc """
  Registers or renews an agent only while its authenticated credential remains current.

  Rechecking the token hash under the source row lock prevents an in-flight
  request authenticated before rotation or reset from recreating a binding.
  """
  def record_authenticated_agent_check_in(
        %Scope{organization_id: organization_id} = scope,
        %Source{} = authenticated_source,
        attrs \\ %{}
      ) do
    source = get_source!(scope, authenticated_source.id)
    do_record_agent_check_in(organization_id, source, attrs, authenticated_source.token_hash)
  end

  @doc """
  Atomically checks in an authenticated agent and accepts its raw observation.

  The authentication state is revalidated under database locks so credential
  or tenant lifecycle changes cannot race either persistent side effect.
  """
  def ingest_authenticated_observation(
        %Scope{organization_id: organization_id} = scope,
        %Source{} = authenticated_source,
        agent_attrs,
        observation_attrs
      ) do
    now = Renga.Time.utc_now_ms()
    installation_id = get_attr(agent_attrs, :installation_id)
    registration_attrs = agent_registration_attrs(authenticated_source, agent_attrs, now)

    Repo.transaction(fn ->
      source = lock_source_for_agent!(organization_id, authenticated_source.id)
      ensure_source_credential_current!(source, authenticated_source.token_hash)
      ensure_organization_active!(organization_id)
      ensure_agent_installation!(organization_id, source.id, installation_id)
      agent = upsert_agent!(organization_id, source.id, registration_attrs)
      lease = put_agent_lease!(organization_id, agent.id, now, 90_000)

      case accept_observation(scope, source.id, observation_attrs) do
        {:ok, observation, disposition} ->
          {agent, lease, observation, disposition}

        {:error, :idempotency_conflict, observation} ->
          Repo.rollback({:idempotency_conflict, observation})

        {:error, reason} ->
          Repo.rollback(reason)
      end
    end)
    |> case do
      {:error, {:idempotency_conflict, observation}} ->
        {:error, :idempotency_conflict, observation}

      result ->
        result
    end
  end

  defp do_record_agent_check_in(organization_id, source, attrs, expected_token_hash) do
    installation_id = get_attr(attrs, :installation_id)

    now =
      attrs
      |> get_attr(:checked_in_at)
      |> case do
        nil -> Renga.Time.utc_now_ms()
        checked_in_at -> Renga.Time.floor_to_millisecond(checked_in_at)
      end

    agent_attrs = agent_registration_attrs(source, attrs, now)

    Repo.transaction(fn ->
      locked_source = lock_source_for_agent!(organization_id, source.id)
      ensure_source_credential_current!(locked_source, expected_token_hash)
      ensure_agent_installation!(organization_id, source.id, installation_id)
      agent = upsert_agent!(organization_id, source.id, agent_attrs)
      lease = put_agent_lease!(organization_id, agent.id, now, 90_000)
      {agent, lease}
    end)
  end

  defp ensure_source_credential_current!(_source, nil), do: :ok

  defp ensure_source_credential_current!(source, expected_token_hash) do
    if source.status == "active" and not is_nil(source.token_hash) and
         source.token_hash == expected_token_hash do
      :ok
    else
      Repo.rollback(:source_credential_changed)
    end
  end

  defp ensure_organization_active!(organization_id) do
    status =
      Organization
      |> where([organization], organization.id == ^organization_id)
      |> select([organization], organization.status)
      |> lock("FOR UPDATE")
      |> Repo.one!()

    if status == "active", do: :ok, else: Repo.rollback(:source_credential_changed)
  end

  defp lock_source_for_agent!(organization_id, source_id) do
    Source
    |> where([source], source.organization_id == ^organization_id)
    |> where([source], source.id == ^source_id)
    |> lock("FOR UPDATE")
    |> Repo.one!()
  end

  defp lock_host_collector(organization_id, source_id) do
    Source
    |> where([source], source.organization_id == ^organization_id)
    |> where([source], source.id == ^source_id and source.kind == "host_agent")
    |> lock("FOR UPDATE")
    |> Repo.one()
  end

  defp fetch_host_collector(%Scope{organization_id: organization_id}, source_id) do
    source =
      Source
      |> where([source], source.organization_id == ^organization_id)
      |> where([source], source.id == ^source_id and source.kind == "host_agent")
      |> Repo.one()

    if source, do: {:ok, source}, else: {:error, :not_found}
  end

  defp ensure_agent_installation!(_organization_id, _source_id, nil), do: :ok

  defp ensure_agent_installation!(organization_id, source_id, installation_id) do
    Agent
    |> where([agent], agent.organization_id == ^organization_id)
    |> where([agent], agent.source_id == ^source_id)
    |> select([agent], agent.installation_id)
    |> Repo.one()
    |> case do
      nil -> :ok
      ^installation_id -> :ok
      _other_installation_id -> Repo.rollback(:installation_identity_mismatch)
    end
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
  Lists registered agents with their source and current lease for operational views.
  """
  def list_agents(%Scope{organization_id: organization_id}) do
    Agent
    |> where([agent], agent.organization_id == ^organization_id)
    |> order_by([agent], asc: agent.name, asc: agent.id)
    |> preload([:source, :lease])
    |> Repo.all()
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
  Lists resources with the typed host and independent conditions needed by
  operational inventory views.
  """
  def list_operational_resources(%Scope{organization_id: organization_id}) do
    Resource
    |> where([resource], resource.organization_id == ^organization_id)
    |> order_by([resource], asc: resource.name, asc: resource.id)
    |> preload([:host, :conditions, identifier_claims: :source])
    |> Repo.all()
  end

  @doc """
  Fetches the complete current operational projection for one scoped resource.

  Raw observations remain separate; this aggregate contains desired state,
  canonical projections, source claims, conditions, and bounded audit history.
  """
  def get_operational_resource!(%Scope{} = scope, id) do
    conditions_query = from(condition in ResourceCondition, order_by: condition.type)

    identifiers_query =
      from(identifier in ResourceIdentifier, order_by: [identifier.kind, identifier.value])

    claims_query =
      from(claim in ResourceIdentifierClaim,
        distinct: [claim.source_id, claim.kind, claim.normalized_value],
        windows: [
          claim_history: [
            partition_by: [claim.source_id, claim.kind, claim.normalized_value]
          ]
        ],
        select_merge: %{
          observation_count: over(count(claim.id), :claim_history)
        },
        order_by: [
          claim.source_id,
          claim.kind,
          claim.normalized_value,
          desc: claim.last_seen_at,
          desc: claim.id
        ],
        preload: [:source]
      )

    events_query =
      from(event in ChangeEvent,
        order_by: [desc: event.occurred_at, desc: event.id],
        limit: 20,
        preload: [:source]
      )

    resource =
      scope
      |> get_resource!(id)
      |> Repo.preload([
        :host,
        conditions: conditions_query,
        identifiers: identifiers_query,
        identifier_claims: claims_query,
        change_events: events_query
      ])

    interfaces =
      scope
      |> list_interfaces(resource.id)
      |> Repo.preload(:addresses)

    %{resource | interfaces: interfaces}
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

      if stored_resource.resource_version != resource.resource_version do
        stored_resource
        |> Resource.changeset(attrs)
        |> Ecto.Changeset.add_error(:resource_version, "is stale")
        |> Repo.rollback()
      end

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
  def put_resource_condition(%Scope{organization_id: organization_id}, resource_id, attrs) do
    Repo.transaction(fn ->
      resource =
        Resource
        |> where([resource], resource.id == ^resource_id)
        |> where([resource], resource.organization_id == ^organization_id)
        |> lock("FOR UPDATE")
        |> Repo.one!()

      type = Map.get(attrs, :type) || Map.get(attrs, "type")

      existing =
        Repo.get_by(ResourceCondition,
          organization_id: organization_id,
          resource_id: resource.id,
          type: type
        )

      transition_at = condition_transition_at(existing, attrs)
      attrs = put_condition_transition_at(attrs, transition_at)

      changeset =
        (existing ||
           %ResourceCondition{
             organization_id: organization_id,
             resource_id: resource.id
           })
        |> ResourceCondition.changeset(attrs)
        |> validate_condition_transition(existing)
        |> validate_condition_generation(existing, resource)

      case Repo.insert_or_update(changeset) do
        {:ok, condition} -> condition
        {:error, changeset} -> Repo.rollback(changeset)
      end
    end)
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

    Repo.transaction(fn ->
      kind = get_attr(attrs, :kind)
      normalized_value = ResourceIdentifier.normalize_value(kind, get_attr(attrs, :value))

      first_seen_at =
        lock_and_update_claim_history(
          organization_id,
          source.id,
          kind,
          normalized_value,
          observation.observed_at
        )

      attrs =
        attrs
        |> put_attr(:first_seen_at, first_seen_at)
        |> put_attr(:last_seen_at, observation.observed_at)

      {resource, resource_identifier, resource_id} = resolve_claim_links(scope, attrs)

      existing_claim =
        Repo.get_by(ResourceIdentifierClaim,
          organization_id: organization_id,
          observation_id: observation.id,
          kind: kind,
          normalized_value: normalized_value
        )

      result =
        (existing_claim ||
           %ResourceIdentifierClaim{
             organization_id: organization_id,
             source_id: source.id,
             observation_id: observation.id
           })
        |> ResourceIdentifierClaim.changeset(attrs)
        |> Ecto.Changeset.put_change(:resource_id, resource_id)
        |> Ecto.Changeset.put_change(
          :resource_identifier_id,
          resource_identifier && resource_identifier.id
        )
        |> validate_claim_resource_link(resource, resource_identifier)
        |> Repo.insert_or_update()

      case result do
        {:ok, claim} -> claim
        {:error, changeset} -> Repo.rollback(changeset)
      end
    end)
  end

  defp lock_and_update_claim_history(
         organization_id,
         source_id,
         kind,
         normalized_value,
         observed_at
       ) do
    claim_history_key =
      [organization_id, source_id, kind, normalized_value]
      |> :erlang.term_to_binary()
      |> Base.encode64()

    Repo.query!("SELECT pg_advisory_xact_lock(hashtextextended($1, 0))", [claim_history_key])

    previous_first_seen_at =
      ResourceIdentifierClaim
      |> where([claim], claim.organization_id == ^organization_id)
      |> where([claim], claim.source_id == ^source_id)
      |> where([claim], claim.kind == ^kind)
      |> where([claim], claim.normalized_value == ^normalized_value)
      |> select([claim], min(claim.first_seen_at))
      |> Repo.one()

    first_seen_at = earliest_timestamp(previous_first_seen_at, observed_at)

    ResourceIdentifierClaim
    |> where([claim], claim.organization_id == ^organization_id)
    |> where([claim], claim.source_id == ^source_id)
    |> where([claim], claim.kind == ^kind)
    |> where([claim], claim.normalized_value == ^normalized_value)
    |> where([claim], claim.first_seen_at > ^first_seen_at)
    |> Repo.update_all(set: [first_seen_at: first_seen_at])

    first_seen_at
  end

  defp resolve_claim_links(scope, attrs) do
    resource = fetch_optional_claim_link(attrs, :resource_id, &get_resource!(scope, &1))

    resource_identifier =
      fetch_optional_claim_link(
        attrs,
        :resource_identifier_id,
        &get_resource_identifier!(scope, &1)
      )

    resource_id =
      case {resource, resource_identifier} do
        {%Resource{id: id}, _resource_identifier} -> id
        {nil, %ResourceIdentifier{resource_id: id}} -> id
        {nil, nil} -> nil
      end

    {resource, resource_identifier, resource_id}
  end

  defp fetch_optional_claim_link(attrs, key, fetch) do
    case get_attr(attrs, key) do
      nil -> nil
      id -> fetch.(id)
    end
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
    attrs = put_attr(attrs, :observed_at, observation.observed_at)

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
    attrs = put_attr(attrs, :observed_at, observation.observed_at)

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
    attrs = put_attr(attrs, :observed_at, observation.observed_at)

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
      |> put_new_attr(:started_at, Renga.Time.utc_now_ms())

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

  The payload digest is always computed by the server so duplicate detection
  cannot be influenced by a caller-provided digest.
  """
  def create_observation(%Scope{organization_id: organization_id} = scope, source_id, attrs) do
    source = get_source!(scope, source_id)
    attrs = normalize_observation_attrs(scope, source.id, attrs)

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
    attrs = normalize_observation_attrs(scope, source.id, attrs)
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
  Reconciles one immutable observation into canonical inventory.
  """
  def reconcile_observation(%Scope{} = scope, observation_id) do
    observation = get_observation!(scope, observation_id)
    Reconciler.reconcile(scope, observation)
  end

  @doc """
  Reconciles one observation for ingestion, returning its existing terminal
  result when another request has already attempted it.
  """
  def reconcile_observation_once(%Scope{} = scope, observation_id) do
    observation = get_observation!(scope, observation_id)
    Reconciler.reconcile_once(scope, observation)
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
    Repo.transaction(fn ->
      resource =
        Resource
        |> where([resource], resource.organization_id == ^scope.organization_id)
        |> where([resource], resource.id == ^resource_id)
        |> lock("FOR UPDATE")
        |> Repo.one!()

      previous_condition =
        ResourceCondition
        |> where([condition], condition.organization_id == ^scope.organization_id)
        |> where([condition], condition.resource_id == ^resource.id)
        |> where([condition], condition.type == "InventoryCurrent")
        |> lock("FOR UPDATE")
        |> Repo.one()

      condition =
        case put_resource_condition(scope, resource.id, %{
               type: "InventoryCurrent",
               status: "false",
               reason: "Stale",
               message: "No current inventory observation is available",
               observed_generation: resource.generation,
               last_transition_at: stale_at
             }) do
          {:ok, condition} -> condition
          {:error, changeset} -> Repo.rollback(changeset)
        end

      if is_nil(previous_condition) or previous_condition.status != "false" do
        {:ok, _event} =
          create_change_event(scope, %{
            kind: "stale",
            field: "conditions.InventoryCurrent",
            resource_id: resource.id,
            old_value: previous_condition && %{"status" => previous_condition.status},
            new_value: %{"status" => "false", "reason" => "Stale"},
            occurred_at: stale_at
          })
      end

      condition
    end)
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
    Repo.transaction(fn ->
      lock_organization!(organization_id)
      resource = get_resource!(scope, resource_id)

      changeset =
        %ResourceOverride{
          organization_id: organization_id,
          resource_id: resource.id,
          created_by_user_id: scope.user && scope.user.id
        }
        |> ResourceOverride.changeset(attrs)
        |> validate_override_contract()

      with {:ok, override} <- Repo.insert(changeset),
           {:ok, old_value} <- materialize_override(scope, resource, override),
           {:ok, _event} <-
             create_change_event(scope, %{
               kind: "manual_override",
               field: override.field,
               resource_id: resource.id,
               old_value: ChangeEvent.audit_value(old_value),
               new_value: override.value |> unwrap_override_value!() |> ChangeEvent.audit_value(),
               metadata: override_provenance(override),
               occurred_at: override.inserted_at
             }) do
        override
      else
        {:error, error} -> Repo.rollback(error)
      end
    end)
  end

  @doc false
  def lock_organization!(organization_id) do
    Repo.query!("SELECT pg_advisory_xact_lock(hashtextextended($1, 0))", [organization_id])
  end

  @host_override_fields ~w(hostname fqdn vendor model asset_tag)
  @interface_override_fields ~w(mac_address kind status mtu speed_mbps)
  @interface_kinds ~w(ethernet loopback bond bridge vlan virtual unknown)
  @interface_statuses ~w(up down dormant not_present unknown)
  @signed_int_max 2_147_483_647

  defp validate_override_contract(changeset) do
    field = Ecto.Changeset.get_field(changeset, :field)
    value = Ecto.Changeset.get_field(changeset, :value)

    case {field, value, parse_override_path(field), unwrap_override_value(value)} do
      {field, _value, _path, _unwrapped} when field in [nil, ""] ->
        changeset

      {_field, _value, :error, _unwrapped} ->
        Ecto.Changeset.add_error(changeset, :field, "is not a supported projection path")

      {_field, _value, {:ok, path}, {:ok, typed_value}} ->
        validate_override_type(changeset, path, typed_value)

      {_field, _value, {:ok, _path}, :error} ->
        Ecto.Changeset.add_error(changeset, :value, "must contain a value")
    end
  end

  defp parse_override_path("host." <> field) when field in @host_override_fields,
    do: {:ok, {:host, field}}

  defp parse_override_path("interfaces." <> rest) do
    case String.split(rest, ".") do
      [name, field] when name != "" and field in @interface_override_fields ->
        {:ok, {:interface, name, field}}

      _other ->
        :error
    end
  end

  defp parse_override_path(_field), do: :error
  defp unwrap_override_value(%{"value" => value}), do: {:ok, value}
  defp unwrap_override_value(%{value: value}), do: {:ok, value}
  defp unwrap_override_value(_value), do: :error

  defp validate_override_type(changeset, {:host, _field}, value) when is_binary(value) do
    if String.length(value) <= 255 do
      changeset
    else
      Ecto.Changeset.add_error(changeset, :value, "must be at most 255 characters")
    end
  end

  defp validate_override_type(changeset, {:interface, _name, "kind"}, value)
       when value in @interface_kinds,
       do: changeset

  defp validate_override_type(changeset, {:interface, _name, "status"}, value)
       when value in @interface_statuses,
       do: changeset

  defp validate_override_type(changeset, {:interface, _name, field}, value)
       when field in ~w(mtu speed_mbps) and is_integer(value) and value > 0 and
              value <= @signed_int_max,
       do: changeset

  defp validate_override_type(changeset, {:interface, _name, "mac_address"}, value) do
    case Renga.Types.MacAddress.cast(value) do
      {:ok, _mac} -> changeset
      :error -> Ecto.Changeset.add_error(changeset, :value, "has an invalid type or value")
    end
  end

  defp validate_override_type(changeset, _path, _value),
    do: Ecto.Changeset.add_error(changeset, :value, "has an invalid type or value")

  defp materialize_override(scope, resource, override) do
    {:ok, path} = parse_override_path(override.field)
    {:ok, value} = unwrap_override_value(override.value)
    owner = override_provenance(override) |> Map.put("source_kind", "manual")

    case path do
      {:host, field} ->
        host = Repo.get_by(Host, organization_id: scope.organization_id, resource_id: resource.id)
        host = host || %Host{organization_id: scope.organization_id, resource_id: resource.id}
        old_value = Map.get(host, String.to_existing_atom(field))
        metadata = put_override_owner(host.metadata, field, owner)
        changeset = Host.changeset(host, %{field => value, "metadata" => metadata})
        persist_projection(host, changeset, old_value)

      {:interface, name, field} ->
        interface =
          Repo.get_by(Interface,
            organization_id: scope.organization_id,
            resource_id: resource.id,
            name: name
          )

        interface =
          interface ||
            %Interface{
              organization_id: scope.organization_id,
              resource_id: resource.id,
              name: name
            }

        old_value = Map.get(interface, String.to_existing_atom(field))
        metadata = put_override_owner(interface.metadata, field, owner)
        changeset = Interface.changeset(interface, %{field => value, "metadata" => metadata})
        persist_projection(interface, changeset, old_value)
    end
  end

  defp persist_projection(%{id: nil}, changeset, old_value),
    do: Repo.insert(changeset) |> projection_result(old_value)

  defp persist_projection(_projection, changeset, old_value),
    do: Repo.update(changeset) |> projection_result(old_value)

  defp projection_result({:ok, _projection}, old_value), do: {:ok, old_value}
  defp projection_result({:error, changeset}, _old_value), do: {:error, changeset}

  defp put_override_owner(metadata, field, owner) do
    metadata = metadata || %{}
    owners = Map.get(metadata, "field_owners", %{})
    Map.put(metadata, "field_owners", Map.put(owners, field, owner))
  end

  defp override_provenance(override) do
    %{
      "override_id" => override.id,
      "created_by_user_id" => override.created_by_user_id,
      "overridden_at" => DateTime.to_iso8601(override.inserted_at)
    }
  end

  defp unwrap_override_value!(value) do
    {:ok, value} = unwrap_override_value(value)
    value
  end

  defp earliest_timestamp(nil, timestamp), do: timestamp

  defp earliest_timestamp(first, second) do
    if DateTime.compare(first, second) == :gt, do: second, else: first
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
      "annotations" => resource.annotations,
      "deletion_requested_at" => resource.deletion_requested_at
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
    |> maybe_put(:installation_id, get_attr(attrs, :installation_id))
    |> maybe_put(:version, get_attr(attrs, :version) || metadata_version(metadata))
    |> maybe_put(:capabilities, get_attr(attrs, :capabilities))
    |> maybe_put(:metadata, metadata)
  end

  defp upsert_agent!(organization_id, source_id, attrs) do
    bind_installation? = Map.has_key?(attrs, :installation_id)
    update_version? = Map.has_key?(attrs, :version)
    update_capabilities? = Map.has_key?(attrs, :capabilities)
    merge_metadata? = Map.has_key?(attrs, :metadata)

    on_conflict =
      from(agent in Agent,
        update: [
          set: [
            name:
              fragment(
                "CASE WHEN EXCLUDED.updated_at >= ? THEN EXCLUDED.name ELSE ? END",
                agent.updated_at,
                agent.name
              ),
            installation_id:
              fragment(
                "CASE WHEN ? AND ? IS NULL THEN EXCLUDED.installation_id ELSE ? END",
                ^bind_installation?,
                agent.installation_id,
                agent.installation_id
              ),
            version:
              fragment(
                "CASE WHEN EXCLUDED.updated_at >= ? AND ? THEN EXCLUDED.version ELSE ? END",
                agent.updated_at,
                ^update_version?,
                agent.version
              ),
            capabilities:
              fragment(
                "CASE WHEN EXCLUDED.updated_at >= ? AND ? THEN EXCLUDED.capabilities ELSE ? END",
                agent.updated_at,
                ^update_capabilities?,
                agent.capabilities
              ),
            metadata:
              fragment(
                "CASE WHEN EXCLUDED.updated_at >= ? AND ? THEN ? || EXCLUDED.metadata ELSE ? END",
                agent.updated_at,
                ^merge_metadata?,
                agent.metadata,
                agent.metadata
              ),
            updated_at:
              fragment(
                "CASE WHEN EXCLUDED.updated_at >= ? THEN EXCLUDED.updated_at ELSE ? END",
                agent.updated_at,
                agent.updated_at
              )
          ]
        ]
      )

    changeset =
      %Agent{organization_id: organization_id, source_id: source_id}
      |> Agent.changeset(attrs)
      |> Ecto.Changeset.put_change(:updated_at, Map.fetch!(attrs, :registered_at))

    changeset =
      case Map.fetch(attrs, :installation_id) do
        {:ok, installation_id} ->
          Ecto.Changeset.put_change(changeset, :installation_id, installation_id)

        :error ->
          changeset
      end

    changeset =
      if merge_metadata? do
        existing_agent =
          Agent
          |> where([agent], agent.organization_id == ^organization_id)
          |> where([agent], agent.source_id == ^source_id)
          |> select([agent], %{metadata: agent.metadata, updated_at: agent.updated_at})
          |> Repo.one()

        case existing_agent do
          nil ->
            validate_agent_metadata_size(changeset, attrs.metadata)

          existing_agent ->
            validate_agent_metadata_merge(changeset, attrs, existing_agent)
        end
      else
        changeset
      end

    result =
      Repo.insert(changeset,
        on_conflict: on_conflict,
        conflict_target: [:organization_id, :source_id],
        returning: true
      )

    case result do
      {:ok, agent} ->
        agent

      {:error, changeset} ->
        if installation_id_conflict?(changeset) do
          Repo.rollback(:installation_identity_conflict)
        else
          Repo.rollback(changeset)
        end
    end
  end

  defp installation_id_conflict?(changeset) do
    Enum.any?(changeset.errors, fn
      {:installation_id, {_message, options}} ->
        options[:constraint_name] == "agents_organization_installation_id_index"

      _other_error ->
        false
    end)
  end

  defp validate_agent_metadata_merge(changeset, attrs, existing_agent) do
    if DateTime.compare(attrs.registered_at, existing_agent.updated_at) in [:eq, :gt] do
      validate_agent_metadata_size(
        changeset,
        Map.merge(existing_agent.metadata, attrs.metadata)
      )
    else
      changeset
    end
  end

  defp validate_agent_metadata_size(changeset, metadata) do
    max_bytes = AgentPayload.max_agent_metadata_bytes()

    if metadata |> Jason.encode!() |> byte_size() <= max_bytes do
      changeset
    else
      Ecto.Changeset.add_error(
        changeset,
        :metadata,
        "must encode to at most #{max_bytes} bytes"
      )
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
    attrs
    |> get_attr(:last_transition_at)
    |> normalize_transition_at()
  end

  defp condition_transition_at(condition, attrs) do
    status = Map.get(attrs, :status) || Map.get(attrs, "status") || condition.status

    if status == condition.status do
      condition.last_transition_at
    else
      attrs
      |> get_attr(:last_transition_at)
      |> normalize_transition_at(condition.last_transition_at)
    end
  end

  defp normalize_transition_at(nil), do: Renga.Time.utc_now_ms()
  defp normalize_transition_at(transition_at), do: Renga.Time.floor_to_millisecond(transition_at)

  defp normalize_transition_at(nil, previous_transition_at),
    do: next_transition_at(previous_transition_at)

  defp normalize_transition_at(transition_at, _previous_transition_at),
    do: Renga.Time.floor_to_millisecond(transition_at)

  defp next_transition_at(previous_transition_at) do
    now = Renga.Time.utc_now_ms()

    if DateTime.compare(now, previous_transition_at) == :gt do
      now
    else
      DateTime.add(previous_transition_at, 1, :millisecond)
    end
  end

  defp validate_condition_transition(changeset, nil), do: changeset

  defp validate_condition_transition(changeset, condition) do
    status = Ecto.Changeset.get_field(changeset, :status)
    transition_at = Ecto.Changeset.get_field(changeset, :last_transition_at)

    if (status != condition.status and transition_at) &&
         DateTime.compare(transition_at, condition.last_transition_at) != :gt do
      Ecto.Changeset.add_error(
        changeset,
        :last_transition_at,
        "must be after the previous transition"
      )
    else
      changeset
    end
  end

  defp validate_condition_generation(changeset, condition, resource) do
    observed_generation = Ecto.Changeset.get_field(changeset, :observed_generation)

    cond do
      observed_generation && observed_generation > resource.generation ->
        Ecto.Changeset.add_error(
          changeset,
          :observed_generation,
          "cannot exceed the resource generation"
        )

      condition && condition.observed_generation &&
          (is_nil(observed_generation) || observed_generation < condition.observed_generation) ->
        Ecto.Changeset.add_error(
          changeset,
          :observed_generation,
          "cannot be older than the current condition"
        )

      true ->
        changeset
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

  defp normalize_observation_attrs(scope, source_id, attrs) do
    payload = Map.get(attrs, :payload) || Map.get(attrs, "payload")

    idempotency_key =
      Map.get(attrs, :idempotency_key) ||
        Map.get(attrs, "idempotency_key") ||
        Map.get(attrs, :observation_id) ||
        Map.get(attrs, "observation_id")

    attrs
    |> put_attr(:idempotency_key, idempotency_key)
    |> put_new_attr(:observed_at, Renga.Time.utc_now_ms())
    |> put_attr(:payload_digest, digest_payload(payload))
    |> normalize_scoped_assoc(
      scope,
      :sync_run_id,
      &get_source_sync_run!(&1, source_id, &2)
    )
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
    |> put_new_attr(:occurred_at, Renga.Time.utc_now_ms())
    |> normalize_scoped_assoc(scope, :resource_id, &get_resource!/2)
    |> normalize_change_event_provenance(scope)
  end

  defp normalize_change_event_provenance(attrs, scope) do
    case get_attr(attrs, :observation_id) do
      nil -> normalize_change_event_without_observation(attrs, scope)
      observation_id -> normalize_change_event_with_observation(attrs, scope, observation_id)
    end
  end

  defp normalize_change_event_with_observation(attrs, scope, observation_id) do
    observation = get_observation!(scope, observation_id)
    source_id = get_attr(attrs, :source_id) || observation.source_id
    sync_run_id = get_attr(attrs, :sync_run_id) || observation.sync_run_id

    get_source_observation!(scope, source_id, observation.id)

    if sync_run_id do
      get_observation_sync_run!(scope, observation.id, sync_run_id)
    end

    attrs
    |> put_attr(:observation_id, observation.id)
    |> put_attr(:source_id, source_id)
    |> put_attr(:sync_run_id, sync_run_id)
  end

  defp normalize_change_event_without_observation(attrs, scope) do
    case get_attr(attrs, :sync_run_id) do
      nil ->
        normalize_scoped_assoc(attrs, scope, :source_id, &get_source!/2)

      sync_run_id ->
        sync_run = get_sync_run!(scope, sync_run_id)
        source_id = get_attr(attrs, :source_id) || sync_run.source_id
        get_source_sync_run!(scope, source_id, sync_run.id)

        attrs
        |> put_attr(:source_id, source_id)
        |> put_attr(:sync_run_id, sync_run.id)
    end
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

    if Map.has_key?(attrs, string_key) or Enum.all?(Map.keys(attrs), &is_binary/1) do
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

  defp get_source_sync_run!(
         %Scope{organization_id: organization_id},
         source_id,
         sync_run_id
       ) do
    SyncRun
    |> where([sync_run], sync_run.organization_id == ^organization_id)
    |> where([sync_run], sync_run.source_id == ^source_id)
    |> Repo.get!(sync_run_id)
  end

  defp get_observation_sync_run!(
         %Scope{organization_id: organization_id},
         observation_id,
         sync_run_id
       ) do
    Observation
    |> where([observation], observation.organization_id == ^organization_id)
    |> where([observation], observation.sync_run_id == ^sync_run_id)
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
