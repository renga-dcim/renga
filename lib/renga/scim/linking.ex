defmodule Renga.Scim.Linking do
  @moduledoc """
  Links directory entries to RFD 15 identities at provider sign-in (RFD 16,
  "Directory entries").

  An entry links to an identity when that identity signs in through the
  entry's connection's provider and the validated ID token's correlation
  claim exactly equals the entry's nonempty `externalId`. Only a nonempty
  string of printable characters, at most 255 bytes, counts as correlation
  evidence; anything else links nothing, though the sign-in itself goes on
  under RFD 15. An entry bound to another identity is never reassigned.
  Renga never links by email.

  An active entry also opens provider sign-up for a person who has no
  account yet, even when the provider does not otherwise allow it.
  """

  import Ecto.Query, warn: false

  alias Renga.Accounts.IdentityProvider
  alias Renga.Accounts.Organization
  alias Renga.Accounts.UserIdentity
  alias Renga.Inventory.ChangeEvent
  alias Renga.Repo
  alias Renga.Scim.Connection
  alias Renga.Scim.DirectoryUser

  @doc """
  Whether an active, unlinked entry of an enabled connection to `provider`
  correlates with `claims`, so a first sign-in may create an account.
  """
  def permits_sign_up?(%IdentityProvider{id: provider_id}, claims) do
    provider_id
    |> candidates(claims)
    |> where([user], user.active and is_nil(user.user_identity_id))
    |> Repo.exists?()
  end

  @doc """
  Binds every entry that correlates with `claims` to `identity`, in the
  sign-in's transaction. Returns the entries that were newly linked.
  """
  def link_identity(%UserIdentity{} = identity, claims) do
    identity.provider_id
    |> candidates(claims)
    |> select([user, connection], {user.id, connection.organization_id})
    |> Repo.all()
    |> Enum.flat_map(fn {entry_id, organization_id} ->
      # The organization lock first, as every grant-changing write takes it.
      # An organization that stopped being active links nothing, and the
      # sign-in goes on.
      with :ok <- lock_organization(organization_id) do
        DirectoryUser |> where(id: ^entry_id) |> lock("FOR UPDATE") |> Repo.one()
      end
      |> case do
        %DirectoryUser{user_identity_id: nil} = entry ->
          [bind!(entry, identity)]

        %DirectoryUser{user_identity_id: bound} = entry when bound != identity.id ->
          record!(entry, "scim_link_refused", identity)
          []

        _already_linked_or_gone ->
          []
      end
    end)
  end

  @doc "Whether `value` is usable correlation evidence."
  def correlation_value?(value) do
    is_binary(value) and value != "" and byte_size(value) <= 255 and String.printable?(value) and
      not String.contains?(value, ["\n", "\r", "\t", "\v", "\f", "\e", "\a", "\b"])
  end

  defp lock_organization(organization_id) do
    Organization
    |> where(
      [organization],
      organization.id == ^organization_id and organization.status == "active"
    )
    |> select([organization], organization.id)
    |> lock("FOR UPDATE")
    |> Repo.one()
    |> if(do: :ok, else: :inactive)
  end

  defp bind!(entry, identity) do
    linked =
      entry
      |> Ecto.Changeset.change(user_identity_id: identity.id)
      |> Repo.update!()

    record!(linked, "scim_user_linked", identity)
    linked
  end

  # Entries of enabled connections to the provider, in active
  # organizations, whose externalId equals that connection's claim.
  defp candidates(provider_id, claims) do
    values =
      for claim <- claims_in_use(provider_id),
          value = Map.get(claims, claim),
          correlation_value?(value),
          do: {claim, value}

    conditions =
      Enum.reduce(values, dynamic(false), fn {claim, value}, acc ->
        dynamic(
          [user, connection],
          ^acc or (connection.correlation_claim == ^claim and user.external_id == ^value)
        )
      end)

    DirectoryUser
    |> join(:inner, [user], connection in Connection, on: connection.id == user.connection_id)
    |> join(:inner, [_user, connection], organization in Organization,
      on: organization.id == connection.organization_id
    )
    |> where([_user, connection], connection.provider_id == ^provider_id)
    |> where([_user, connection], is_nil(connection.disabled_at))
    |> where([_user, _connection, organization], organization.status == "active")
    |> where(^conditions)
  end

  defp claims_in_use(provider_id) do
    Connection
    |> where(
      [connection],
      connection.provider_id == ^provider_id and is_nil(connection.disabled_at)
    )
    |> select([connection], connection.correlation_claim)
    |> distinct(true)
    |> Repo.all()
  end

  defp record!(entry, kind, identity) do
    %ChangeEvent{organization_id: entry.organization_id, actor_user_id: identity.user_id}
    |> ChangeEvent.changeset(%{
      kind: kind,
      metadata: %{
        "connection_id" => entry.connection_id,
        "scim_user_id" => entry.id,
        "user_name" => entry.user_name,
        "user_identity_id" => identity.id,
        "provider_id" => identity.provider_id
      },
      occurred_at: Renga.Time.utc_now_ms()
    })
    |> Repo.insert!()
  end
end
