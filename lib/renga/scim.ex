defmodule Renga.Scim do
  @moduledoc """
  SCIM provisioning connections and their tokens (RFD 16, "Connections").

  An organization owner connects the organization to one `oidc` identity
  provider it can see: a deployment provider, or a provider the organization
  owns. Connecting needs `scim.manage`, which only owners hold and no custom
  role may carry, because a connection's mappings can grant any built-in
  role. An organization has at most one enabled connection, and the
  connection's provider and correlation claim never change in place: a
  replacement means disabling the old connection and creating another.

  A connection authenticates its provider with bearer tokens, at most two
  unrevoked at a time so one can be rotated without downtime. A token's value
  is returned once when it is issued and only its SHA-256 hash is kept, like
  an intake key's. `authenticate/1` is the only way a token is used, and only
  the `/scim/v2` endpoints call it.

  Every change is an Activity entry naming the owner who made it. Token
  values never reach Activity, logs, or any other record.
  """

  import Ecto.Query, warn: false

  alias Renga.Accounts.IdentityProvider
  alias Renga.Accounts.Organization
  alias Renga.Accounts.Scope
  alias Renga.Authorization
  alias Renga.Inventory.ChangeEvent
  alias Renga.Inventory.Changes
  alias Renga.Repo
  alias Renga.Scim.Connection
  alias Renga.Scim.DirectoryGroup
  alias Renga.Scim.Grants
  alias Renga.Scim.Token

  @token_prefix "renga_scim_"
  @token_bytes 32
  @max_active_tokens 2

  # Renga always permits `sub`. Another claim is eligible only once the
  # provider's configuration declares it stable and unique, which RFD 15
  # provider revisions do not record yet.
  @correlation_claims ~w(sub)

  @doc "UI hint for `scim.manage`."
  def can_manage?(%Scope{} = scope), do: Authorization.allowed?(scope, "scim.manage")

  @doc "How many unrevoked tokens a connection may hold."
  def max_active_tokens, do: @max_active_tokens

  @doc "The correlation claims a connection to `provider` may use."
  def correlation_claims(%IdentityProvider{kind: "oidc"}), do: @correlation_claims
  def correlation_claims(%IdentityProvider{}), do: []

  @doc """
  Whether the organization has an enabled SCIM connection. RFD 15 claim
  mappings must refuse an organization for which this is true, since an
  organization has one external membership authority.
  """
  def enabled_connection?(organization_id) when is_binary(organization_id) do
    Connection
    |> where([connection], connection.organization_id == ^organization_id)
    |> where([connection], is_nil(connection.disabled_at))
    |> Repo.exists?()
  end

  @doc "The organization's connections, the enabled one first, then newest first."
  def list_connections(%Scope{organization_id: organization_id}) do
    Connection
    |> where([connection], connection.organization_id == ^organization_id)
    |> order_by([connection],
      asc: not is_nil(connection.disabled_at),
      desc: connection.inserted_at
    )
    |> preload([:provider, tokens: ^active_tokens()])
    |> Repo.all()
  end

  @doc "A connection in the caller's organization, with its unrevoked tokens, or nil."
  def get_connection(%Scope{organization_id: organization_id}, id) do
    case Ecto.UUID.cast(id || "") do
      {:ok, id} ->
        Connection
        |> where([connection], connection.organization_id == ^organization_id)
        |> where([connection], connection.id == ^id)
        |> preload([:provider, tokens: ^active_tokens()])
        |> Repo.one()

      :error ->
        nil
    end
  end

  @doc """
  The providers a connection in the caller's organization may name: enabled
  `oidc` providers that belong to the deployment or to this organization.
  """
  def eligible_providers(%Scope{organization_id: organization_id}) do
    organization_id
    |> eligible_providers_query()
    |> order_by([provider], asc: provider.display_name, asc: provider.id)
    |> Repo.all()
  end

  def change_connection(%Connection{} = connection, attrs \\ %{}),
    do: Connection.create_changeset(connection, attrs)

  @doc """
  Connects the organization to a provider. `attrs` names the
  `"provider_id"`, and may name the `"correlation_claim"` (`"sub"` by
  default) and a `"default_role"`.

  Returns `{:error, changeset}` when the provider is not eligible, the claim
  is not one the provider permits, or the organization already has an
  enabled connection.
  """
  def create_connection(%Scope{} = scope, attrs) do
    provider_id = attrs["provider_id"] || attrs[:provider_id]

    managed(scope, provider_id, fn ->
      changeset =
        %Connection{organization_id: scope.organization_id, created_by_user_id: scope.user.id}
        |> Connection.create_changeset(attrs)
        |> validate_provider(scope.organization_id)
        |> validate_no_enabled_connection(scope.organization_id)

      with {:ok, connection} <- Repo.insert(changeset) do
        record!(scope, "scim_connection_created", connection, nil, %{
          "provider_id" => connection.provider_id,
          "correlation_claim" => connection.correlation_claim,
          "default_role" => connection.default_role
        })

        {:ok, connection}
      end
    end)
  end

  @doc """
  Changes the role every active provisioned user gets, or clears it with
  `nil` or `""`.
  """
  def update_default_role(%Scope{} = scope, connection_id, role) do
    with_connection(scope, connection_id, fn connection ->
      with {:ok, updated} <-
             connection
             |> Connection.default_role_changeset(%{default_role: role})
             |> Repo.update() do
        record_default_role!(scope, connection, updated)
        reconcile_connection!(scope, updated)
        {:ok, updated}
      end
    end)
  end

  defp record_default_role!(_scope, %{default_role: role}, %{default_role: role}), do: :ok

  defp record_default_role!(scope, connection, updated) do
    record!(
      scope,
      "scim_default_role_changed",
      updated,
      connection.default_role && %{"value" => connection.default_role},
      updated.default_role && %{"value" => updated.default_role}
    )
  end

  @doc """
  Disables a connection: its tokens stop authenticating at once. A disabled
  connection stays as history, and its tokens stay revocable.
  """
  def disable_connection(%Scope{} = scope, connection_id) do
    with_connection(scope, connection_id, fn connection ->
      if Connection.enabled?(connection) do
        disabled =
          connection
          |> Ecto.Changeset.change(disabled_at: Renga.Time.utc_now_ms())
          |> Repo.update!()

        record!(scope, "scim_connection_disabled", disabled)
        reconcile_connection!(scope, disabled)
        {:ok, disabled}
      else
        {:ok, connection}
      end
    end)
  end

  @doc """
  Re-enables a disabled connection, unless the organization has enabled
  another one since or its provider is no longer eligible.
  """
  def enable_connection(%Scope{} = scope, connection_id) do
    provider_id = connection_provider_id(scope, connection_id)

    with_connection(scope, provider_id, connection_id, fn connection ->
      cond do
        Connection.enabled?(connection) ->
          {:ok, connection}

        enabled_connection?(scope.organization_id) ->
          {:error, :already_connected}

        not eligible_provider?(connection.provider_id, scope.organization_id) ->
          {:error, :provider_unavailable}

        true ->
          enabled =
            connection
            |> Ecto.Changeset.change(disabled_at: nil)
            |> Repo.update!()

          record!(scope, "scim_connection_enabled", enabled)
          reconcile_connection!(scope, enabled)
          {:ok, enabled}
      end
    end)
  end

  @doc """
  Maps a directory group to a built-in role, or unmaps it with `nil` or
  `""`. The mapping names the group's Renga-assigned id, so renaming the
  group keeps it and a recreated group starts unmapped. Members' grants
  change before this returns.
  """
  def map_group(%Scope{} = scope, group_id, role) do
    role = if role == "", do: nil, else: role

    managed(scope, fn ->
      with :ok <- check_role(role),
           {:ok, group} <- lock_group(scope, group_id),
           do: remap!(scope, group, role)
    end)
  end

  defp remap!(_scope, %DirectoryGroup{role: role} = group, role), do: {:ok, group}

  defp remap!(scope, group, role) do
    mapped = group |> Ecto.Changeset.change(role: role) |> Repo.update!()
    connection = Repo.get!(Connection, group.connection_id)

    record!(
      scope,
      "scim_group_mapped",
      connection,
      group.role && %{"value" => group.role},
      role && %{"value" => role},
      %{"scim_group_id" => group.id, "group" => group.display_name}
    )

    Grants.reconcile!(
      scope.organization_id,
      Grants.users_of_group(group.id),
      cause(scope, connection)
    )

    {:ok, mapped}
  end

  defp check_role(nil), do: :ok

  defp check_role(role),
    do: if(role in Authorization.built_in_roles(), do: :ok, else: {:error, :invalid_role})

  defp lock_group(%Scope{organization_id: organization_id}, group_id) do
    with {:ok, id} <- Ecto.UUID.cast(group_id || ""),
         %DirectoryGroup{} = group <-
           DirectoryGroup
           |> where([group], group.organization_id == ^organization_id and group.id == ^id)
           |> lock("FOR UPDATE")
           |> Repo.one() do
      {:ok, group}
    else
      _missing -> {:error, :not_found}
    end
  end

  @doc """
  Brings the connections to a provider in line after the provider is
  enabled, disabled, or removed (RFD 16, "Memberships"). Removal disables
  them and clears their entries' bindings. Runs inside the provider
  change's transaction, which holds the provider lock; each organization
  is locked after it, as a sign-in does.
  """
  def provider_changed!(%IdentityProvider{id: provider_id} = provider) do
    Connection
    |> where([connection], connection.provider_id == ^provider_id)
    |> where([connection], is_nil(connection.disabled_at))
    |> Repo.all()
    |> Enum.each(&provider_changed!(provider, &1))
  end

  # An inactive organization's grants authorize nothing, so it is left for
  # whenever it is reactivated; removal still retires its connection.
  defp provider_changed!(provider, connection) do
    active? = Grants.lock_organization(connection.organization_id) == :ok
    users = if active?, do: Grants.users_of_connection(connection), else: []
    if provider.removed_at, do: retire!(connection)
    Grants.reconcile!(connection.organization_id, users, %{"connection_id" => connection.id})
  end

  defp retire!(connection) do
    Repo.update_all(where(Connection, id: ^connection.id),
      set: [disabled_at: Renga.Time.utc_now_ms()]
    )

    Repo.update_all(where(Renga.Scim.DirectoryUser, connection_id: ^connection.id),
      set: [user_identity_id: nil]
    )
  end

  defp reconcile_connection!(scope, connection) do
    users = Grants.users_of_connection(connection)
    Grants.reconcile!(scope.organization_id, users, cause(scope, connection))
  end

  defp cause(scope, connection), do: %{:actor => scope.user.id, "connection_id" => connection.id}

  @doc """
  Issues a token for a connection. Returns `{:ok, {token, value}}`; `value`
  is never available again. Refuses with `:too_many_tokens` while the
  connection already holds two unrevoked tokens.
  """
  def create_token(%Scope{} = scope, connection_id, attrs) do
    with_connection(scope, connection_id, fn connection ->
      value = generate_token()

      changeset =
        %Token{
          organization_id: scope.organization_id,
          connection_id: connection.id,
          created_by_user_id: scope.user.id
        }
        |> Token.create_changeset(attrs, hash_token(value))

      with :ok <- check_token_room(connection),
           {:ok, token} <- Repo.insert(changeset) do
        record!(scope, "scim_token_created", connection, nil, nil, token_metadata(token))
        {:ok, {token, value}}
      end
    end)
  end

  @doc "Revokes a token at once. Revoking a revoked token changes nothing."
  def revoke_token(%Scope{} = scope, token_id) do
    managed(scope, fn ->
      with {:ok, token} <- lock_token(scope, token_id), do: revoke!(scope, token)
    end)
  end

  defp revoke!(_scope, %Token{revoked_at: %DateTime{}} = token), do: {:ok, token}

  defp revoke!(scope, token) do
    revoked =
      token
      |> Ecto.Changeset.change(
        revoked_at: Renga.Time.utc_now_ms(),
        revoked_by_user_id: scope.user.id
      )
      |> Repo.update!()

    connection = Repo.get!(Connection, token.connection_id)
    record!(scope, "scim_token_revoked", connection, nil, nil, token_metadata(revoked))
    {:ok, revoked}
  end

  @doc """
  The connection a SCIM bearer token authenticates, with its organization
  and the token, or `:error`. Only an unrevoked token of an enabled
  connection, in an active organization, whose provider is still enabled and
  not removed, authenticates.
  """
  def authenticate(@token_prefix <> _rest = value) do
    token_hash = hash_token(value)

    Token
    |> join(:inner, [token], connection in assoc(token, :connection))
    |> join(:inner, [_token, connection], organization in Organization,
      on: organization.id == connection.organization_id
    )
    |> join(:inner, [_token, connection], provider in IdentityProvider,
      on: provider.id == connection.provider_id
    )
    |> where([token], token.token_hash == ^token_hash and is_nil(token.revoked_at))
    |> where([_token, connection], is_nil(connection.disabled_at))
    |> where([_token, _connection, organization], organization.status == "active")
    |> where([_token, _connection, _organization, provider], provider.enabled)
    |> where([_token, _connection, _organization, provider], is_nil(provider.removed_at))
    |> select([token, connection, organization], {token, connection, organization})
    |> Repo.one()
    |> case do
      {token, connection, organization} ->
        {:ok, %{connection | organization: organization}, token}

      nil ->
        :error
    end
  end

  def authenticate(_value), do: :error

  @doc """
  Records that a token was used. The clock moves at most once a minute, so
  a provider's burst of requests does not write on every one.
  """
  def touch_token(%Token{id: id}) do
    now = Renga.Time.utc_now_ms()
    stale = DateTime.add(now, -60, :second)

    Token
    |> where([token], token.id == ^id)
    |> where([token], is_nil(token.last_used_at) or token.last_used_at < ^stale)
    |> Repo.update_all(set: [last_used_at: now])

    :ok
  end

  # Connection administration locks the organization, like every other
  # authorization-changing write, and then the connection.
  #
  # Creating or re-enabling a connection first holds its provider, as a
  # sign-in does, so a provider being disabled or removed meanwhile either
  # waits and then reconciles the connection, or is seen as ineligible.
  defp managed(%Scope{} = scope, provider_id \\ nil, mutation) do
    Grants.announcing(fn -> transact(scope, provider_id, mutation) end)
    |> Changes.broadcast(scope.organization_id)
  end

  defp transact(scope, provider_id, mutation) do
    Repo.transaction(fn ->
      if is_binary(provider_id), do: lock_provider(provider_id)
      Authorization.authorize!(scope, "scim.manage")

      case mutation.() do
        {:ok, result} -> result
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  defp with_connection(scope, provider_id \\ nil, connection_id, mutation) do
    managed(scope, provider_id, fn ->
      with {:ok, connection} <- lock_connection(scope, connection_id), do: mutation.(connection)
    end)
  end

  defp lock_provider(provider_id) do
    IdentityProvider
    |> where([provider], provider.id == ^provider_id)
    |> lock("FOR SHARE")
    |> Repo.one()
  end

  # Read before any lock; a connection's provider never changes.
  defp connection_provider_id(%Scope{organization_id: organization_id}, connection_id) do
    case Ecto.UUID.cast(connection_id || "") do
      {:ok, id} ->
        Connection
        |> where([connection], connection.organization_id == ^organization_id)
        |> where([connection], connection.id == ^id)
        |> select([connection], connection.provider_id)
        |> Repo.one()

      :error ->
        nil
    end
  end

  defp lock_connection(%Scope{organization_id: organization_id}, connection_id) do
    with {:ok, id} <- Ecto.UUID.cast(connection_id || ""),
         %Connection{} = connection <-
           Connection
           |> where([connection], connection.organization_id == ^organization_id)
           |> where([connection], connection.id == ^id)
           |> lock("FOR UPDATE")
           |> Repo.one() do
      {:ok, connection}
    else
      _missing -> {:error, :not_found}
    end
  end

  defp lock_token(%Scope{organization_id: organization_id}, token_id) do
    with {:ok, id} <- Ecto.UUID.cast(token_id || ""),
         %Token{} = token <-
           Token
           |> where([token], token.organization_id == ^organization_id)
           |> where([token], token.id == ^id)
           |> lock("FOR UPDATE")
           |> Repo.one() do
      {:ok, token}
    else
      _missing -> {:error, :not_found}
    end
  end

  # The connection row is locked, so two concurrent issues cannot both see
  # room for a third token.
  defp check_token_room(%Connection{id: id}) do
    active =
      Token
      |> where([token], token.connection_id == ^id and is_nil(token.revoked_at))
      |> Repo.aggregate(:count)

    if active < @max_active_tokens, do: :ok, else: {:error, :too_many_tokens}
  end

  defp active_tokens do
    Token
    |> where([token], is_nil(token.revoked_at))
    |> order_by([token], asc: token.inserted_at)
  end

  defp validate_provider(changeset, organization_id) do
    provider_id = Ecto.Changeset.get_field(changeset, :provider_id)

    provider =
      provider_id && Repo.one(where(eligible_providers_query(organization_id), id: ^provider_id))

    cond do
      is_nil(provider_id) ->
        changeset

      is_nil(provider) ->
        Ecto.Changeset.add_error(
          changeset,
          :provider_id,
          "is not an available OpenID Connect provider"
        )

      Ecto.Changeset.get_field(changeset, :correlation_claim) not in correlation_claims(provider) ->
        Ecto.Changeset.add_error(
          changeset,
          :correlation_claim,
          "is not a stable claim this provider declares"
        )

      true ->
        changeset
    end
  end

  defp validate_no_enabled_connection(changeset, organization_id) do
    if enabled_connection?(organization_id),
      do: Ecto.Changeset.add_error(changeset, :organization_id, "already has a SCIM connection"),
      else: changeset
  end

  defp eligible_provider?(provider_id, organization_id) do
    organization_id
    |> eligible_providers_query()
    |> where([provider], provider.id == ^provider_id)
    |> Repo.exists?()
  end

  # GitHub has no SCIM client, so only OpenID Connect providers qualify. An
  # organization's own provider qualifies only for that organization.
  defp eligible_providers_query(organization_id) do
    IdentityProvider
    |> where([provider], provider.kind == "oidc")
    |> where([provider], provider.enabled and is_nil(provider.removed_at))
    |> where(
      [provider],
      is_nil(provider.organization_id) or provider.organization_id == ^organization_id
    )
  end

  defp generate_token,
    do:
      @token_prefix <> Base.url_encode64(:crypto.strong_rand_bytes(@token_bytes), padding: false)

  # Tokens carry 256 random bits, so a fast hash is enough.
  defp hash_token(value), do: :crypto.hash(:sha256, value)

  defp token_metadata(token), do: %{"token_id" => token.id, "token" => token.name}

  defp record!(scope, kind, connection, old \\ nil, new \\ nil, metadata \\ %{}) do
    %ChangeEvent{organization_id: scope.organization_id, actor_user_id: scope.user.id}
    |> ChangeEvent.changeset(%{
      kind: kind,
      old_value: old,
      new_value: new,
      metadata:
        Map.merge(
          %{"connection_id" => connection.id, "provider_id" => connection.provider_id},
          metadata
        ),
      occurred_at: Renga.Time.utc_now_ms()
    })
    |> Repo.insert!()
  end
end
