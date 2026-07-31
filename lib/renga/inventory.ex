defmodule Renga.Inventory do
  @moduledoc """
  Inventory source and resource management.

  The inventory context owns organization-scoped sources now and will absorb
  observations, reconciliation, and freshness state in later phases.
  """

  import Ecto.Query, warn: false

  alias Renga.Accounts.Scope
  alias Renga.Inventory.Address
  alias Renga.Inventory.Interface
  alias Renga.Inventory.Resource
  alias Renga.Inventory.ResourceIdentifier
  alias Renga.Inventory.Source
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

    %ResourceIdentifier{
      organization_id: organization_id,
      resource_id: resource.id
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

  defp generate_source_token do
    @source_token_prefix <>
      Base.url_encode64(:crypto.strong_rand_bytes(@source_token_bytes), padding: false)
  end

  # SHA-256 is sufficient here because source tokens are high-entropy random
  # secrets, unlike user passwords that need slow Argon2 hashing.
  defp hash_source_token(token), do: :crypto.hash(:sha256, token)
end
