defmodule Renga.Roles do
  @moduledoc """
  Custom roles (RFD 17, "Roles"): named sets of permissions an organization
  defines beside the four built-in roles, such as a "network engineer" with
  `inventory.reconcile`, `findings.act`, `ipam.edit`, and `topology.edit`.

  Defining, changing, or deleting a role needs `roles.manage`, and every
  permission in the role, before and after the change, must be within the
  grant ceiling of the actor's current built-in role
  (`Renga.Authorization.grantable_permissions/1`): only owners may include
  the owner-only organization permissions, and no custom role may carry
  `members.manage` or `roles.manage`. Every change is an Activity entry.
  """

  import Ecto.Query, warn: false

  alias Renga.Accounts.Scope
  alias Renga.Assignments
  alias Renga.Authorization
  alias Renga.Inventory.ChangeEvent
  alias Renga.Inventory.Changes
  alias Renga.Repo
  alias Renga.Roles.Assignment
  alias Renga.Roles.Role

  @doc "UI hint for `roles.manage`."
  def can_manage?(%Scope{} = scope), do: Authorization.allowed?(scope, "roles.manage")

  @doc """
  The permissions the scope's cached role may put in a role, for the form.
  The transaction re-reads the actor's role before relying on it.
  """
  def grantable_permissions(%Scope{} = scope) do
    if can_manage?(scope), do: Authorization.grantable_permissions(scope.roles), else: []
  end

  @doc "The organization's custom roles by name."
  def list_roles(%Scope{organization_id: organization_id}) do
    Role
    |> where([role], role.organization_id == ^organization_id)
    |> order_by([role], asc: fragment("lower(?)", role.name))
    |> Repo.all()
  end

  @doc "A custom role in the caller's organization, or nil."
  def get_role(%Scope{organization_id: organization_id}, id) do
    case Ecto.UUID.cast(id || "") do
      {:ok, id} -> Repo.get_by(Role, id: id, organization_id: organization_id)
      :error -> nil
    end
  end

  def change_role(%Role{} = role, attrs \\ %{}), do: Role.changeset(role, attrs)

  @doc "Defines a custom role."
  def create_role(%Scope{} = scope, attrs) do
    managed(scope, fn ceiling ->
      changeset =
        %Role{organization_id: scope.organization_id}
        |> Role.changeset(attrs)
        |> validate_ceiling(ceiling)

      with {:ok, role} <- Repo.insert(changeset) do
        record!(scope, "role_created", nil, role)
        {:ok, role}
      end
    end)
  end

  @doc """
  Renames a role or changes its permissions. Everyone who holds it gains or
  loses access at once, so the actor's ceiling must cover the role both
  before and after.
  """
  def update_role(%Scope{} = scope, %Role{} = role, attrs) do
    managed(scope, fn ceiling ->
      with {:ok, current} <- lock_role(scope, role.id),
           :ok <- within_ceiling(current.permissions, ceiling),
           {:ok, updated} <-
             current |> Role.changeset(attrs) |> validate_ceiling(ceiling) |> Repo.update() do
        record!(scope, "role_updated", current, updated)
        {:ok, updated}
      end
    end)
  end

  @doc """
  Deletes a custom role whose permissions are within the actor's ceiling,
  and with it every assignment of the role. Activity records how many
  assignments went with it.
  """
  def delete_role(%Scope{} = scope, %Role{} = role) do
    managed(scope, fn ceiling ->
      with {:ok, current} <- lock_role(scope, role.id),
           :ok <- within_ceiling(current.permissions, ceiling),
           assignments = Repo.aggregate(where(Assignment, role_id: ^current.id), :count),
           :ok <- Assignments.record_expired_for_role!(scope.organization_id, current.id),
           {:ok, deleted} <- Repo.delete(current) do
        record!(scope, "role_deleted", current, nil, %{"assignments" => assignments})
        {:ok, deleted}
      end
    end)
  end

  # Checks roles.manage and hands the mutation the permissions the actor's
  # current built-in role may grant.
  defp managed(%Scope{} = scope, mutation) do
    Repo.transaction(fn ->
      Authorization.authorize!(scope, "roles.manage")
      ceiling = scope |> Authorization.current_roles!() |> Authorization.grantable_permissions()

      case mutation.(ceiling) do
        {:ok, result} -> result
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
    |> Changes.broadcast(scope.organization_id)
  end

  defp validate_ceiling(changeset, ceiling) do
    Ecto.Changeset.validate_change(changeset, :permissions, fn :permissions, permissions ->
      case permissions -- ceiling do
        [] -> []
        above -> [permissions: "includes #{Enum.join(above, ", ")}, which you may not grant"]
      end
    end)
  end

  defp within_ceiling(permissions, ceiling),
    do: if(permissions -- ceiling == [], do: :ok, else: {:error, :forbidden})

  defp lock_role(%Scope{organization_id: organization_id}, id) do
    Role
    |> where([role], role.organization_id == ^organization_id and role.id == ^id)
    |> lock("FOR UPDATE")
    |> Repo.one()
    |> case do
      nil -> {:error, :not_found}
      role -> {:ok, role}
    end
  end

  defp record!(scope, kind, before, after_role, metadata \\ %{}) do
    %ChangeEvent{organization_id: scope.organization_id, actor_user_id: scope.user.id}
    |> ChangeEvent.changeset(%{
      kind: kind,
      field: "role",
      old_value: role_value(before),
      new_value: role_value(after_role),
      metadata: Map.put(metadata, "role_id", (after_role || before).id),
      occurred_at: Renga.Time.utc_now_ms()
    })
    |> Repo.insert!()
  end

  defp role_value(nil), do: nil

  defp role_value(%Role{} = role),
    do: %{"name" => role.name, "permissions" => role.permissions}
end
