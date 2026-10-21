defmodule Renga.Members do
  @moduledoc """
  An organization's members and their base roles (RFD 17, "Administration").

  Holders of `members.manage` change a member's base role and disable or
  re-enable them. What they may change is bounded by the grant ceiling of
  their own built-in role (`Renga.Authorization.grantable_roles/1`): an admin
  manages admins, members, and viewers, and only an owner manages owners.

  An organization always keeps at least one active owner, its recovery
  owner, so no change may disable or demote the last one. Every change is
  an Activity entry with its actor, the before and after values, and the
  reason given. Authorization-changing writes take the organization lock
  first, like every other protected mutation, so they serialize with the
  decisions they affect.
  """

  import Ecto.Query, warn: false

  alias Renga.Accounts.OrganizationMembership
  alias Renga.Accounts.Scope
  alias Renga.Authorization
  alias Renga.Inventory.ChangeEvent
  alias Renga.Inventory.Changes
  alias Renga.Repo

  @doc "UI hint for `members.manage`."
  def can_manage?(%Scope{} = scope), do: Authorization.allowed?(scope, "members.manage")

  @doc """
  The roles the scope's cached role may grant, for pickers. The transaction
  re-reads the actor's role before relying on it.
  """
  def grantable_roles(%Scope{} = scope) do
    if can_manage?(scope),
      do: scope.roles |> Enum.flat_map(&Authorization.grantable_roles/1) |> Enum.uniq(),
      else: []
  end

  @doc "Every member of the organization, active and disabled, by email."
  def list_members(%Scope{organization_id: organization_id}) do
    OrganizationMembership
    |> join(:inner, [membership], user in assoc(membership, :user))
    |> where([membership], membership.organization_id == ^organization_id)
    |> order_by([membership, user], asc: membership.status, asc: user.email)
    |> preload([_membership, user], user: user)
    |> Repo.all()
  end

  @doc """
  Changes a member's base role. `opts` may carry a `:reason` for Activity.

  Returns `{:error, :forbidden}` when the actor lacks `members.manage` or
  either role is above their grant ceiling, and `{:error, :last_owner}` when
  it would demote the organization's last active owner.
  """
  def change_role(%Scope{} = scope, membership_id, role, opts \\ []) do
    administer(scope, membership_id, fn actor_ceiling, member ->
      cond do
        role not in Authorization.built_in_roles() ->
          {:error, :invalid_role}

        member.role == role ->
          {:ok, member}

        role not in actor_ceiling ->
          {:error, :forbidden}

        last_active_owner?(member) ->
          {:error, :last_owner}

        true ->
          update!(scope, member, :role, role, "member_role_changed", opts)
      end
    end)
  end

  @doc """
  Disables a member: they can no longer open the organization, and their
  role grants nothing. Their membership and history stay. People cannot
  disable themselves.
  """
  def disable_member(%Scope{} = scope, membership_id, opts \\ []) do
    administer(scope, membership_id, fn _actor_ceiling, member ->
      cond do
        member.status == "disabled" -> {:ok, member}
        member.id == scope.membership_id -> {:error, :self}
        last_active_owner?(member) -> {:error, :last_owner}
        true -> update!(scope, member, :status, "disabled", "member_disabled", opts)
      end
    end)
  end

  @doc "Re-enables a disabled member with the base role they had."
  def enable_member(%Scope{} = scope, membership_id, opts \\ []) do
    administer(scope, membership_id, fn _actor_ceiling, member ->
      if member.status == "active",
        do: {:ok, member},
        else: update!(scope, member, :status, "active", "member_enabled", opts)
    end)
  end

  # Checks members.manage and locks the target. Administering a member is
  # bounded by the ceiling of the actor's current role, re-read here rather
  # than trusted from the scope: the target's current role must be within it.
  defp administer(%Scope{} = scope, membership_id, change) do
    Repo.transaction(fn ->
      Authorization.authorize!(scope, "members.manage")
      ceiling = scope |> actor_role() |> Authorization.grantable_roles()

      with {:ok, member} <- lock_member(scope, membership_id),
           true <- member.role in ceiling || {:error, :forbidden},
           {:ok, member} <- change.(ceiling, member) do
        Repo.preload(member, :user)
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
    |> Changes.broadcast(scope.organization_id)
  end

  # authorize!/3 has already locked the actor's membership.
  defp actor_role(%Scope{membership_id: membership_id}) do
    OrganizationMembership
    |> where([membership], membership.id == ^membership_id)
    |> select([membership], membership.role)
    |> Repo.one!()
  end

  defp lock_member(%Scope{organization_id: organization_id}, membership_id) do
    with {:ok, id} <- Ecto.UUID.cast(membership_id),
         %OrganizationMembership{} = member <-
           OrganizationMembership
           |> where([membership], membership.organization_id == ^organization_id)
           |> where([membership], membership.id == ^id)
           |> lock("FOR UPDATE")
           |> Repo.one() do
      {:ok, member}
    else
      _missing -> {:error, :not_found}
    end
  end

  # The organization lock taken by authorize!/3 serializes every membership
  # change, so counting the other active owners here cannot race.
  defp last_active_owner?(%OrganizationMembership{role: "owner", status: "active"} = member) do
    not (OrganizationMembership
         |> where([membership], membership.organization_id == ^member.organization_id)
         |> where([membership], membership.id != ^member.id)
         |> where([membership], membership.role == "owner" and membership.status == "active")
         |> Repo.exists?())
  end

  defp last_active_owner?(%OrganizationMembership{}), do: false

  defp update!(scope, member, field, value, kind, opts) do
    old = Map.fetch!(member, field)

    member =
      member
      |> Ecto.Changeset.change(%{field => value})
      |> Repo.update!()

    member = Repo.preload(member, :user)

    %ChangeEvent{organization_id: scope.organization_id, actor_user_id: scope.user.id}
    |> ChangeEvent.changeset(%{
      kind: kind,
      field: Atom.to_string(field),
      old_value: %{"value" => old},
      new_value: %{"value" => value},
      metadata: activity_metadata(member, opts[:reason]),
      occurred_at: Renga.Time.utc_now_ms()
    })
    |> Repo.insert!()

    {:ok, member}
  end

  defp activity_metadata(member, reason) do
    %{"membership_id" => member.id, "member" => member.user.email}
    |> then(&if(present?(reason), do: Map.put(&1, "reason", String.trim(reason)), else: &1))
  end

  defp present?(value), do: is_binary(value) and String.trim(value) != ""
end
