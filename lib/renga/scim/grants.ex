defmodule Renga.Scim.Grants do
  @moduledoc """
  Membership grants from SCIM (RFD 16, "Memberships").

  A linked, active directory entry of an organization's enabled connection
  grants a membership. Its role is the highest of the connection's default
  role and the roles mapped from the entry's groups; with neither, the entry
  grants nothing. A grant is valid only while its source is: the connection
  and its provider are enabled, and the entry is active and linked to an
  existing identity of that provider.

  A grant is an `organization_memberships` row naming the connection. A
  membership granted by hand names none, takes precedence, and is never
  changed or removed here. Losing SCIM authority disables a granted
  membership rather than deleting it, so its teams, assignments, and
  history come back with the person; the account itself is never touched.

  Every function here runs inside a transaction that holds the
  organization lock, and returns the memberships whose access changed so
  the caller can tell connected sessions after the commit.
  """

  import Ecto.Query, warn: false

  alias Renga.Accounts.IdentityProvider
  alias Renga.Accounts.OrganizationMembership
  alias Renga.Accounts.User
  alias Renga.Accounts.UserIdentity
  alias Renga.Inventory.ChangeEvent
  alias Renga.Repo
  alias Renga.Scim.Connection
  alias Renga.Scim.DirectoryGroup
  alias Renga.Scim.DirectoryUser
  alias Renga.Scim.GroupMember

  @role_order ~w(owner admin member viewer)

  @doc """
  The account ids `entry_ids` reach through their identity bindings. Call it
  before and after a change, and reconcile both sets, so an account that
  lost its binding is reconciled too.
  """
  def users_of_entries([]), do: []

  def users_of_entries(entry_ids) do
    DirectoryUser
    |> join(:inner, [user], identity in UserIdentity, on: identity.id == user.user_identity_id)
    |> where([user], user.id in ^entry_ids)
    |> select([_user, identity], identity.user_id)
    |> distinct(true)
    |> Repo.all()
  end

  @doc "The account ids the members of `group_id` reach."
  def users_of_group(group_id) do
    GroupMember
    |> where([member], member.group_id == ^group_id)
    |> select([member], member.user_id)
    |> Repo.all()
    |> users_of_entries()
  end

  @doc """
  Every account a connection may have granted to: those its entries reach
  and those holding a membership it granted.
  """
  def users_of_connection(%Connection{id: id}) do
    reached =
      DirectoryUser
      |> where([user], user.connection_id == ^id)
      |> select([user], user.id)
      |> Repo.all()
      |> users_of_entries()

    granted =
      OrganizationMembership
      |> where([membership], membership.scim_connection_id == ^id)
      |> select([membership], membership.user_id)
      |> Repo.all()

    Enum.uniq(reached ++ granted)
  end

  @doc """
  Brings the SCIM grants of `user_ids` in the organization up to date.
  `cause` is metadata for the Activity entries, such as the connection,
  token, and request ID behind the change. Returns the memberships whose
  role or status changed.
  """
  def reconcile!(organization_id, user_ids, cause \\ %{}) do
    connection = active_connection(organization_id)

    user_ids
    |> Enum.uniq()
    |> Enum.sort()
    |> Enum.flat_map(&reconcile_user!(organization_id, connection, &1, cause))
  end

  @doc """
  Locks the organization for a grant change, as every authorization-changing
  write does first. Returns `:inactive` instead of rolling back, for callers
  such as a sign-in that go on without it.
  """
  def lock_organization(organization_id) do
    Renga.Accounts.Organization
    |> where([organization], organization.id == ^organization_id)
    |> where([organization], organization.status == "active")
    |> select([organization], organization.id)
    |> lock("FOR UPDATE")
    |> Repo.one()
    |> if(do: :ok, else: :inactive)
  end

  @doc "The role SCIM grants `user_id` in the organization now, or nil."
  def granted_role(organization_id, user_id) do
    organization_id |> active_connection() |> desired_role(user_id)
  end

  defp reconcile_user!(organization_id, connection, user_id, cause) do
    membership =
      OrganizationMembership
      |> where([membership], membership.organization_id == ^organization_id)
      |> where([membership], membership.user_id == ^user_id)
      |> lock("FOR UPDATE")
      |> Repo.one()

    apply_grant!(
      organization_id,
      membership,
      connection,
      user_id,
      desired_role(connection, user_id),
      cause
    )
  end

  # Nothing to grant and nothing granted.
  defp apply_grant!(_organization_id, nil, _connection, _user_id, nil, _cause), do: []

  defp apply_grant!(organization_id, nil, connection, user_id, role, cause) do
    membership =
      %OrganizationMembership{
        organization_id: organization_id,
        user_id: user_id,
        role: role,
        status: "active",
        scim_connection_id: connection.id
      }
      |> Repo.insert!()

    record!(membership, "scim_grant_added", nil, role, cause)
    [membership]
  end

  # A membership granted by hand takes precedence.
  defp apply_grant!(
         _organization_id,
         %OrganizationMembership{scim_connection_id: nil},
         _c,
         _u,
         _r,
         _cause
       ),
       do: []

  defp apply_grant!(
         _organization_id,
         %OrganizationMembership{status: "disabled"},
         _c,
         _u,
         nil,
         _cause
       ),
       do: []

  defp apply_grant!(_organization_id, membership, _connection, _user_id, nil, cause) do
    disabled = membership |> Ecto.Changeset.change(status: "disabled") |> Repo.update!()
    record!(disabled, "scim_grant_removed", membership.role, nil, cause)
    [disabled]
  end

  defp apply_grant!(
         _organization_id,
         %OrganizationMembership{status: "active", role: role},
         _c,
         _u,
         role,
         _cause
       ),
       do: []

  defp apply_grant!(_organization_id, membership, connection, _user_id, role, cause) do
    old = if membership.status == "active", do: membership.role

    updated =
      membership
      |> Ecto.Changeset.change(role: role, status: "active", scim_connection_id: connection.id)
      |> Repo.update!()

    record!(
      updated,
      if(old, do: "scim_grant_changed", else: "scim_grant_added"),
      old,
      role,
      cause
    )

    [updated]
  end

  # The organization's enabled connection, if its provider is usable.
  defp active_connection(organization_id) do
    Connection
    |> join(:inner, [connection], provider in IdentityProvider,
      on: provider.id == connection.provider_id
    )
    |> where([connection], connection.organization_id == ^organization_id)
    |> where([connection], is_nil(connection.disabled_at))
    |> where([_connection, provider], provider.enabled and is_nil(provider.removed_at))
    |> Repo.one()
  end

  defp desired_role(nil, _user_id), do: nil

  defp desired_role(%Connection{} = connection, user_id) do
    entries =
      DirectoryUser
      |> join(:inner, [user], identity in UserIdentity, on: identity.id == user.user_identity_id)
      |> where([user], user.connection_id == ^connection.id and user.active)
      |> where([_user, identity], identity.user_id == ^user_id)
      |> where([_user, identity], identity.provider_id == ^connection.provider_id)
      |> select([user], user.id)
      |> Repo.all()

    mapped =
      if entries == [] do
        []
      else
        GroupMember
        |> join(:inner, [member], group in DirectoryGroup, on: group.id == member.group_id)
        |> where([member], member.user_id in ^entries)
        |> where([_member, group], not is_nil(group.role))
        |> select([_member, group], group.role)
        |> Repo.all()
      end

    if entries == [], do: nil, else: highest([connection.default_role | mapped])
  end

  defp highest(roles), do: Enum.find(@role_order, &(&1 in roles))

  # An owner's change carries them as `actor`; a provider's has no actor.
  defp record!(membership, kind, old, new, cause) do
    {actor, cause} = Map.pop(cause, :actor)

    member =
      Repo.one(from user in User, where: user.id == ^membership.user_id, select: user.email)

    %ChangeEvent{organization_id: membership.organization_id, actor_user_id: actor}
    |> ChangeEvent.changeset(%{
      kind: kind,
      field: "role",
      old_value: old && %{"value" => old},
      new_value: new && %{"value" => new},
      metadata:
        Map.merge(cause, %{
          "membership_id" => membership.id,
          "member" => member,
          "user_id" => membership.user_id,
          "connection_id" => membership.scim_connection_id
        }),
      occurred_at: Renga.Time.utc_now_ms()
    })
    |> Repo.insert!()
  end
end
