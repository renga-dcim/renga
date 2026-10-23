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
  alias Renga.Scim.Grants

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
    candidates = candidates(identity.provider_id, claims)

    candidates
    |> select([user, connection], {connection.organization_id, user.id})
    |> Repo.all()
    # Organizations are locked in one order, so two sign-ins that reach the
    # same organizations cannot deadlock.
    |> Enum.sort()
    |> Enum.flat_map(fn {organization_id, entry_id} ->
      # The organization lock first, as every grant-changing write takes it.
      # An organization that stopped being active links nothing, and the
      # sign-in goes on. Once it is held, the entry is read again under the
      # candidate rules: a SCIM write or connection change that committed
      # meanwhile may have taken the correlation away.
      with :ok <- Grants.lock_organization(organization_id) do
        DirectoryUser
        |> where(id: ^entry_id)
        |> where([user], user.id in subquery(select(candidates, [user], user.id)))
        |> lock("FOR UPDATE")
        |> Repo.one()
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

  @doc """
  Releases every entry bound to `identity` before the identity is deleted,
  and brings the account's grants in those organizations up to date, in
  the caller's transaction. Deleting the identity alone would clear the
  bindings but keep the memberships they granted, and no later SCIM change
  could reach the account to remove them.

  The caller holds the identity's row lock (`FOR UPDATE`), so a sign-in
  that links it has either committed, and its bindings are found here, or
  waits until the identity is gone.
  """
  def unlink_identity!(%UserIdentity{id: identity_id, user_id: user_id}) do
    DirectoryUser
    |> where([user], user.user_identity_id == ^identity_id)
    |> select([user], user.organization_id)
    |> distinct(true)
    |> Repo.all()
    # The same order and lock as a sign-in's linking. An organization that
    # stopped being active keeps its grants for whenever it is reactivated,
    # as a provider change leaves them.
    |> Enum.sort()
    |> Enum.each(fn organization_id ->
      with :ok <- Grants.lock_organization(organization_id) do
        DirectoryUser
        |> where([user], user.user_identity_id == ^identity_id)
        |> where([user], user.organization_id == ^organization_id)
        |> Repo.update_all(set: [user_identity_id: nil])

        Grants.reconcile!(organization_id, [user_id], %{"user_identity_id" => identity_id})
      end
    end)
  end

  @doc "Whether `value` is usable correlation evidence."
  def correlation_value?(value) do
    is_binary(value) and value != "" and byte_size(value) <= 255 and String.printable?(value) and
      not String.contains?(value, ["\n", "\r", "\t", "\v", "\f", "\e", "\a", "\b"])
  end

  defp bind!(entry, identity) do
    linked =
      entry
      |> Ecto.Changeset.change(user_identity_id: identity.id)
      |> Repo.update!()

    record!(linked, "scim_user_linked", identity)

    Grants.reconcile!(linked.organization_id, [identity.user_id], %{
      "connection_id" => linked.connection_id,
      "user_identity_id" => identity.id
    })

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
