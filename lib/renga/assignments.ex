defmodule Renga.Assignments do
  @moduledoc """
  Assignments give a member further roles beyond their base role (RFD 17,
  "Assignments"): a built-in role, or one of the organization's custom
  roles, optionally until a deadline. A person may do what the union of
  their base role and current assignments allows; an expired assignment
  grants nothing.

  Giving or taking away an assignment needs `members.manage`, and the role
  must be within the grant ceiling of the actor's current built-in roles:
  a built-in role from `Renga.Authorization.grantable_roles/1`, a custom
  role whose permissions all come from
  `Renga.Authorization.grantable_permissions/1`. Every change is an
  Activity entry with its actor, the member, the role, and the reason.
  """

  import Ecto.Query, warn: false

  alias Renga.Accounts.OrganizationMembership
  alias Renga.Accounts.Organization
  alias Renga.Accounts.Scope
  alias Renga.Authorization
  alias Renga.Inventory.ChangeEvent
  alias Renga.Inventory.Changes
  alias Renga.Repo
  alias Renga.Roles.Assignment
  alias Renga.Roles.Role

  @expiry_batch 500

  @doc "UI hint for giving and taking away assignments."
  def can_manage?(%Scope{} = scope), do: Authorization.allowed?(scope, "members.manage")

  @doc """
  The roles the scope's cached roles may assign, for the picker: built-in
  role names and custom roles. The transaction re-checks both.
  """
  def assignable_roles(%Scope{} = scope) do
    if can_manage?(scope) do
      permissions = Authorization.grantable_permissions(scope.roles)

      custom =
        scope
        |> list_roles()
        |> Enum.filter(&(&1.permissions -- permissions == []))

      %{built_in: Authorization.grantable_roles(scope.roles), custom: custom}
    else
      %{built_in: [], custom: []}
    end
  end

  @doc """
  The organization's assignments, expired ones included, with their roles,
  members, and creators, newest first.
  """
  def list_assignments(%Scope{organization_id: organization_id}) do
    Assignment
    |> where([assignment], assignment.organization_id == ^organization_id)
    |> order_by([assignment], desc: assignment.inserted_at)
    |> preload([:role, :created_by_user, membership: :user])
    |> Repo.all()
  end

  @doc """
  How many people and current assignments hold each custom role, keyed by
  role id, so the role page can say what a change affects.
  """
  def role_usage(%Scope{organization_id: organization_id}) do
    now = Renga.Time.utc_now_ms()

    Assignment
    |> where([assignment], assignment.organization_id == ^organization_id)
    |> where([assignment], not is_nil(assignment.role_id))
    |> where([assignment], is_nil(assignment.valid_until) or assignment.valid_until > ^now)
    |> group_by([assignment], assignment.role_id)
    |> select([assignment], {
      assignment.role_id,
      %{people: count(assignment.membership_id, :distinct), assignments: count(assignment.id)}
    })
    |> Repo.all()
    |> Map.new()
  end

  @doc "The next assignment deadline in an organization, for live UI refreshes."
  def next_expiry(%Scope{organization_id: organization_id}) do
    now = Renga.Time.utc_now_ms()

    Assignment
    |> where([assignment], assignment.organization_id == ^organization_id)
    |> where([assignment], is_nil(assignment.expired_at))
    |> where([assignment], assignment.valid_until > ^now)
    |> select([assignment], min(assignment.valid_until))
    |> Repo.one()
  end

  @doc """
  Records each elapsed assignment deadline in Activity exactly once.

  Authorization continues to use `valid_until` directly; this sweep only
  makes that already-effective expiry durable and visible. Rows are claimed
  with `SKIP LOCKED`, so retries and workers on several nodes are safe.
  """
  def sweep_expired(now \\ Renga.Time.utc_now_ms()) do
    Assignment
    |> where([assignment], is_nil(assignment.expired_at))
    |> where([assignment], not is_nil(assignment.valid_until) and assignment.valid_until <= ^now)
    |> order_by([assignment], asc: assignment.valid_until, asc: assignment.id)
    |> limit(@expiry_batch)
    |> select([assignment], {assignment.id, assignment.organization_id})
    |> Repo.all()
    |> Enum.count(&expire_one(&1, now))
  end

  @doc false
  # Called from the organization-locked role deletion transaction before its
  # cascade removes assignment rows. This closes the gap between the deadline
  # taking effect and the periodic audit sweep observing it.
  def record_expired_for_role!(organization_id, role_id, now \\ Renga.Time.utc_now_ms()) do
    assignments =
      Assignment
      |> where([assignment], assignment.organization_id == ^organization_id)
      |> where([assignment], assignment.role_id == ^role_id)
      |> where([assignment], is_nil(assignment.expired_at))
      |> where(
        [assignment],
        not is_nil(assignment.valid_until) and assignment.valid_until <= ^now
      )
      |> order_by([assignment], asc: assignment.valid_until, asc: assignment.id)
      |> lock("FOR UPDATE")
      |> Repo.all()

    Enum.each(assignments, &expire_assignment!(&1, now))
    :ok
  end

  def change_assignment(attrs \\ %{}),
    do: Assignment.changeset(%Assignment{}, attrs, Renga.Time.utc_now_ms())

  @doc """
  Gives the member `membership_id` the role named by `attrs["role"]`: a
  built-in role name or a custom role's id. `attrs` may carry
  `"valid_until"` and `"reason"`.

  Returns `{:error, :forbidden}` when the actor lacks `members.manage` or
  the role is above their ceiling, `{:error, :already_assigned}` when the
  member already holds a current assignment of the role, and
  `{:error, changeset}` for an invalid role, deadline, or reason.
  """
  def assign(%Scope{} = scope, membership_id, attrs) do
    administer(scope, fn ceiling ->
      now = Renga.Time.utc_now_ms()

      with {:ok, member} <- lock_member(scope, membership_id),
           {:ok, role} <- resolve_role(scope, attrs["role"]),
           :ok <- within_ceiling(role, ceiling),
           :ok <- not_assigned(member, role, now),
           {:ok, assignment} <-
             %Assignment{
               organization_id: scope.organization_id,
               membership_id: member.id,
               created_by_user_id: scope.user.id
             }
             |> put_role(role)
             |> Assignment.changeset(attrs, now)
             |> Repo.insert() do
        assignment = Repo.preload(assignment, [:role, membership: :user])

        record!(scope, "role_assigned", nil, assignment, assignment.reason)
        {:ok, assignment}
      end
    end)
  end

  @doc """
  Takes away an assignment whose role is within the actor's ceiling, expired
  or not. `opts` may carry a `:reason` for Activity.
  """
  def unassign(%Scope{} = scope, assignment_id, opts \\ []) do
    administer(scope, fn ceiling ->
      with {:ok, assignment} <- lock_assignment(scope, assignment_id),
           :ok <- within_ceiling(assignment.role || assignment.built_in_role, ceiling),
           {:ok, deleted} <- Repo.delete(assignment) do
        record_removal!(scope, assignment, opts[:reason])
        {:ok, deleted}
      end
    end)
  end

  # Taking away a current assignment is the actor's change; an expired one
  # records its expiry unless that was already recorded.
  defp record_removal!(scope, assignment, reason) do
    cond do
      Assignment.current?(assignment, Renga.Time.utc_now_ms()) ->
        record!(scope, "role_unassigned", assignment, nil, reason)

      is_nil(assignment.expired_at) ->
        record_expiry!(assignment)

      true ->
        :ok
    end
  end

  defp administer(%Scope{} = scope, mutation) do
    Repo.transaction(fn ->
      Authorization.authorize!(scope, "members.manage")
      roles = Authorization.current_roles!(scope)

      ceiling = %{
        roles: Authorization.grantable_roles(roles),
        permissions: Authorization.grantable_permissions(roles)
      }

      case mutation.(ceiling) do
        {:ok, result} -> result
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
    |> Changes.broadcast(scope.organization_id)
  end

  defp list_roles(%Scope{organization_id: organization_id}) do
    Role
    |> where([role], role.organization_id == ^organization_id)
    |> order_by([role], asc: fragment("lower(?)", role.name))
    |> Repo.all()
  end

  # A built-in role name, or a custom role in the organization, locked so it
  # cannot change under the ceiling check.
  defp resolve_role(scope, role) when is_binary(role) do
    if role in Authorization.built_in_roles() do
      {:ok, role}
    else
      with {:ok, id} <- Ecto.UUID.cast(role),
           %Role{} = role <-
             Role
             |> where([role], role.organization_id == ^scope.organization_id and role.id == ^id)
             |> lock("FOR SHARE")
             |> Repo.one() do
        {:ok, role}
      else
        _unknown -> {:error, invalid_role()}
      end
    end
  end

  defp resolve_role(_scope, _role), do: {:error, invalid_role()}

  defp invalid_role do
    %Assignment{}
    |> Ecto.Changeset.cast(%{"built_in_role" => ""}, [:built_in_role])
    |> Ecto.Changeset.validate_required([:built_in_role], message: "choose a role")
    |> Map.put(:action, :insert)
  end

  defp within_ceiling(role, ceiling) when is_binary(role),
    do: if(role in ceiling.roles, do: :ok, else: {:error, :forbidden})

  defp within_ceiling(%Role{permissions: permissions}, ceiling),
    do: if(permissions -- ceiling.permissions == [], do: :ok, else: {:error, :forbidden})

  defp put_role(assignment, role) when is_binary(role), do: %{assignment | built_in_role: role}
  defp put_role(assignment, %Role{} = role), do: %{assignment | role_id: role.id, role: role}

  # The member's lock serializes assignments to them, so this cannot race.
  defp not_assigned(member, role, now) do
    Assignment
    |> where([assignment], assignment.membership_id == ^member.id)
    |> where_role(role)
    |> where([assignment], is_nil(assignment.valid_until) or assignment.valid_until > ^now)
    |> Repo.exists?()
    |> if(do: {:error, :already_assigned}, else: :ok)
  end

  defp where_role(query, role) when is_binary(role),
    do: where(query, [assignment], assignment.built_in_role == ^role)

  defp where_role(query, %Role{id: id}),
    do: where(query, [assignment], assignment.role_id == ^id)

  defp lock_member(%Scope{organization_id: organization_id}, membership_id) do
    with {:ok, id} <- Ecto.UUID.cast(membership_id || ""),
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

  defp lock_assignment(%Scope{organization_id: organization_id}, assignment_id) do
    with {:ok, id} <- Ecto.UUID.cast(assignment_id || ""),
         %Assignment{} = assignment <-
           Assignment
           |> where([assignment], assignment.organization_id == ^organization_id)
           |> where([assignment], assignment.id == ^id)
           |> lock("FOR UPDATE")
           |> Repo.one() do
      {:ok, Repo.preload(assignment, [:role, membership: :user])}
    else
      _missing -> {:error, :not_found}
    end
  end

  defp expire_one({assignment_id, organization_id}, now) do
    Repo.transaction(fn ->
      # Authorization-changing writers lock the organization first. Following
      # the same order keeps expiry from deadlocking with assignment removal or
      # a cascading role deletion.
      Organization
      |> where([organization], organization.id == ^organization_id)
      |> lock("FOR UPDATE")
      |> Repo.one()

      assignment =
        Assignment
        |> where([assignment], assignment.id == ^assignment_id)
        |> where([assignment], is_nil(assignment.expired_at))
        |> where(
          [assignment],
          not is_nil(assignment.valid_until) and assignment.valid_until <= ^now
        )
        |> lock("FOR UPDATE SKIP LOCKED")
        |> Repo.one()

      if assignment do
        expire_assignment!(assignment, now)
      end
    end)
    |> case do
      {:ok, nil} ->
        false

      {:ok, assignment} ->
        Changes.broadcast({:ok, assignment}, assignment.organization_id)
        true
    end
  end

  defp expire_assignment!(assignment, now) do
    assignment = Repo.preload(assignment, [:role, membership: :user])
    record_expiry!(assignment)

    assignment
    |> Ecto.Changeset.change(expired_at: now)
    |> Repo.update!()
  end

  defp record!(scope, kind, before, after_assignment, reason) do
    assignment = after_assignment || before
    value = %{"value" => Assignment.role_name(assignment)}

    metadata =
      %{
        "assignment_id" => assignment.id,
        "membership_id" => assignment.membership_id,
        "member" => member_label(assignment),
        "role_id" => assignment.role_id,
        "valid_until" => assignment.valid_until && DateTime.to_iso8601(assignment.valid_until),
        "reason" => reason
      }
      |> Map.reject(fn {_key, value} -> is_nil(value) end)

    %ChangeEvent{organization_id: scope.organization_id, actor_user_id: scope.user.id}
    |> ChangeEvent.changeset(%{
      kind: kind,
      field: "role",
      old_value: before && value,
      new_value: after_assignment && value,
      metadata: metadata,
      occurred_at: Renga.Time.utc_now_ms()
    })
    |> Repo.insert!()
  end

  defp member_label(%{membership: membership}),
    do: Renga.Accounts.label_in_organization(membership.user, membership.organization_id)

  defp record_expiry!(assignment) do
    value = %{"value" => Assignment.role_name(assignment)}

    %ChangeEvent{organization_id: assignment.organization_id}
    |> ChangeEvent.changeset(%{
      kind: "role_expired",
      field: "role",
      old_value: value,
      metadata: %{
        "assignment_id" => assignment.id,
        "membership_id" => assignment.membership_id,
        "member" => member_label(assignment),
        "role_id" => assignment.role_id,
        "valid_until" => DateTime.to_iso8601(assignment.valid_until)
      },
      occurred_at: assignment.valid_until
    })
    |> Repo.insert!()
  end
end
