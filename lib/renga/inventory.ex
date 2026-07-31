defmodule Renga.Inventory do
  @moduledoc """
  Inventory source and resource management.

  The inventory context owns organization-scoped sources now and will absorb
  observations, reconciliation, and freshness state in later phases.
  """

  import Ecto.Query, warn: false

  alias Renga.Accounts.Scope
  alias Renga.Inventory.Address
  alias Renga.Inventory.ChangeEvent
  alias Renga.Inventory.Interface
  alias Renga.Inventory.InterfaceRelationship
  alias Renga.Inventory.Observation
  alias Renga.Inventory.Resource
  alias Renga.Inventory.ResourceIdentifier
  alias Renga.Inventory.ResourceOverride
  alias Renga.Inventory.Source
  alias Renga.Inventory.SyncRun
  alias Renga.Repo

  @source_token_prefix "renga_src_"
  @source_token_bytes 32

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
    |> Repo.one()
    |> case do
      %Source{} = source -> {:ok, source}
      nil -> :error
    end
  end

  def authenticate_source_token(_token), do: :error

  @doc """
  Lists canonical resources visible inside the caller's organization scope.
  """
  def list_resources(%Scope{organization_id: organization_id}) do
    Resource
    |> where([resource], resource.organization_id == ^organization_id)
    |> order_by([resource], asc: resource.hostname, asc: resource.id)
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
    %Resource{organization_id: organization_id}
    |> Resource.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Updates canonical resource fields without changing its tenant.
  """
  def update_resource(%Resource{} = resource, attrs) do
    resource
    |> Resource.changeset(attrs)
    |> Repo.update()
  end

  @doc """
  Builds a resource changeset for UI/API validation.
  """
  def change_resource(%Resource{} = resource, attrs \\ %{}) do
    Resource.changeset(resource, attrs)
  end

  @doc """
  Lists observed identifiers for a resource in the caller's organization.
  """
  def list_resource_identifiers(%Scope{organization_id: organization_id}, resource_id) do
    ResourceIdentifier
    |> where([identifier], identifier.organization_id == ^organization_id)
    |> where([identifier], identifier.resource_id == ^resource_id)
    |> order_by([identifier], asc: identifier.kind, asc: identifier.value)
    |> Repo.all()
  end

  @doc """
  Adds observed identity evidence to a resource.

  The organization id is copied from the caller scope and the resource must be
  fetched through the same scope before this function is called.
  """
  def create_resource_identifier(
        %Scope{organization_id: organization_id} = scope,
        resource_id,
        attrs
      ) do
    resource = get_resource!(scope, resource_id)
    attrs = normalize_source_attrs(scope, attrs)

    %ResourceIdentifier{
      organization_id: organization_id,
      resource_id: resource.id,
      source_id: source_id_from_attrs(attrs)
    }
    |> ResourceIdentifier.changeset(attrs)
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
    attrs = normalize_source_attrs(scope, attrs)

    %Interface{
      organization_id: organization_id,
      resource_id: resource.id,
      source_id: source_id_from_attrs(attrs)
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
    attrs = normalize_source_attrs(scope, attrs)

    %Address{
      organization_id: organization_id,
      resource_id: interface.resource_id,
      interface_id: interface.id,
      source_id: source_id_from_attrs(attrs)
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
  organization. Optional `source_id` is provenance for the collector that
  observed the relationship.
  """
  def create_interface_relationship(
        %Scope{organization_id: organization_id} = scope,
        source_interface_id,
        target_interface_id,
        attrs
      ) do
    source_interface = get_interface!(scope, source_interface_id)
    target_interface = get_interface!(scope, target_interface_id)
    attrs = normalize_source_attrs(scope, attrs)

    %InterfaceRelationship{
      organization_id: organization_id,
      source_interface_id: source_interface.id,
      target_interface_id: target_interface.id,
      source_id: source_id_from_attrs(attrs)
    }
    |> InterfaceRelationship.changeset(attrs)
    |> Repo.insert()
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
      |> Map.put_new(:started_at, DateTime.utc_now(:second))

    %SyncRun{
      organization_id: organization_id,
      source_id: source.id
    }
    |> SyncRun.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Lists raw observations for a scoped resource, newest first.
  """
  def list_observations(%Scope{organization_id: organization_id}, resource_id) do
    Observation
    |> where([observation], observation.organization_id == ^organization_id)
    |> where([observation], observation.resource_id == ^resource_id)
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
      sync_run_id: Map.get(attrs, :sync_run_id) || Map.get(attrs, "sync_run_id"),
      resource_id: Map.get(attrs, :resource_id) || Map.get(attrs, "resource_id")
    }
    |> Observation.changeset(attrs)
    |> Repo.insert()
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
  Marks a resource stale inside the caller's organization.

  Staleness is a canonical resource state, while the companion change event
  keeps a durable explanation for later timelines.
  """
  def mark_resource_stale(%Scope{} = scope, resource_id, stale_at \\ DateTime.utc_now(:second)) do
    resource = get_resource!(scope, resource_id)

    resource
    |> Resource.changeset(%{
      status: "stale",
      stale_at: stale_at,
      last_changed_at: stale_at
    })
    |> Repo.update()
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

  defp normalize_observation_attrs(scope, attrs) do
    payload = Map.get(attrs, :payload) || Map.get(attrs, "payload")

    attrs
    |> Map.put_new(:observed_at, DateTime.utc_now(:second))
    |> Map.put_new(:payload_digest, digest_payload(payload))
    |> normalize_scoped_assoc(scope, :sync_run_id, &get_sync_run!/2)
    |> normalize_scoped_assoc(scope, :resource_id, &get_resource!/2)
  end

  defp normalize_change_event_attrs(scope, attrs) do
    attrs
    |> Map.put_new(:occurred_at, DateTime.utc_now(:second))
    |> normalize_scoped_assoc(scope, :source_id, &get_source!/2)
    |> normalize_scoped_assoc(scope, :resource_id, &get_resource!/2)
    |> normalize_scoped_assoc(scope, :sync_run_id, &get_sync_run!/2)
    |> normalize_scoped_assoc(scope, :observation_id, &get_observation!/2)
  end

  defp normalize_source_attrs(scope, attrs) do
    normalize_scoped_assoc(attrs, scope, :source_id, &get_source!/2)
  end

  defp source_id_from_attrs(attrs), do: Map.get(attrs, :source_id) || Map.get(attrs, "source_id")

  defp normalize_scoped_assoc(attrs, scope, field, fetch_fun) do
    value = Map.get(attrs, field) || Map.get(attrs, Atom.to_string(field))

    if is_nil(value) do
      attrs
    else
      record = fetch_fun.(scope, value)
      Map.put(attrs, field, record.id)
    end
  end

  defp get_observation!(%Scope{organization_id: organization_id}, id) do
    Observation
    |> where([observation], observation.organization_id == ^organization_id)
    |> Repo.get!(id)
  end

  defp digest_payload(nil), do: digest_payload(%{})

  defp digest_payload(payload) do
    payload
    |> :erlang.term_to_binary()
    |> then(&:crypto.hash(:sha256, &1))
  end
end
