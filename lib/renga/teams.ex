defmodule Renga.Teams do
  @moduledoc """
  Teams and the resources they own (RFD 8, "Triage").

  Owners and admins manage teams and set owners; members request an owner
  change through `Renga.Requests`. Every owner change is a resource revision
  and an Activity entry with its actor. A team can be deleted while it owns
  resources: they become unowned, each with its own Activity entry, and so
  return to triage.
  """

  import Ecto.Query, warn: false

  alias Renga.Accounts.Organization
  alias Renga.Accounts.OrganizationMembership
  alias Renga.Accounts.Scope
  alias Renga.Inventory
  alias Renga.Inventory.Changes
  alias Renga.Inventory.Resource
  alias Renga.Repo
  alias Renga.Teams.Team

  @doc "UI hint: owners and admins manage teams and owners."
  def can_manage?(%Scope{} = scope), do: Inventory.organization_manager?(scope)

  ## Teams

  @doc "The organization's teams by name, each with the number of resources it owns."
  def list_teams(%Scope{organization_id: organization_id}) do
    owned =
      from resource in Resource,
        where:
          resource.organization_id == ^organization_id and not is_nil(resource.owner_team_id),
        group_by: resource.owner_team_id,
        select: %{team_id: resource.owner_team_id, count: count(resource.id)}

    Team
    |> where([team], team.organization_id == ^organization_id)
    |> join(:left, [team], owned in subquery(owned), on: owned.team_id == team.id)
    |> order_by([team], asc: fragment("lower(?)", team.name))
    |> select([team, owned], %{team | resource_count: coalesce(owned.count, 0)})
    |> Repo.all()
  end

  @doc "Fetches a team in the caller's organization, or nil (ids often come from a URL)."
  def get_team(%Scope{organization_id: organization_id}, id) do
    case Ecto.UUID.cast(id || "") do
      {:ok, id} -> Repo.get_by(Team, id: id, organization_id: organization_id)
      :error -> nil
    end
  end

  @doc "A changeset for the team form."
  def change_team(%Team{} = team, attrs \\ %{}), do: Team.changeset(team, attrs)

  @doc "Creates a team. Owners and admins only."
  def create_team(%Scope{organization_id: organization_id} = scope, attrs) do
    managed(scope, fn ->
      %Team{organization_id: organization_id}
      |> Team.changeset(attrs)
      |> Repo.insert()
    end)
  end

  @doc "Renames or re-describes a team. Owners and admins only."
  def update_team(%Scope{} = scope, %Team{} = team, attrs) do
    managed(scope, fn ->
      scope
      |> lock_team!(team.id)
      |> Team.changeset(attrs)
      |> Repo.update()
    end)
  end

  @doc """
  Deletes a team. Its resources become unowned, each recorded in Activity,
  so they return to triage. Owners and admins only.
  """
  def delete_team(%Scope{organization_id: organization_id} = scope, %Team{} = team) do
    managed(scope, fn ->
      team = lock_team!(scope, team.id)

      Resource
      |> where([resource], resource.organization_id == ^organization_id)
      |> where([resource], resource.owner_team_id == ^team.id)
      |> select([resource], resource.id)
      |> Repo.all()
      |> Enum.each(&put_owner!(scope, &1, nil, team))

      Repo.delete(team)
    end)
  end

  ## Owners

  @doc """
  Sets a resource's owning team, or clears it with nil. Owners and admins
  only; members request the change instead.
  """
  def set_owner(%Scope{} = scope, %Resource{} = resource, team_id) do
    with {:ok, 1} <- set_owners(scope, [resource.id], team_id) do
      {:ok, Inventory.get_resource!(scope, resource.id)}
    end
  end

  @doc """
  Sets one owning team on several resources at once, in one transaction.
  Ids outside the caller's organization are ignored, as they come from a
  shareable URL. Returns `{:ok, changed_count}`.
  """
  def set_owners(%Scope{organization_id: organization_id} = scope, ids, team_id)
      when is_list(ids) do
    ids = Enum.flat_map(ids, &List.wrap(cast_id(&1)))

    managed(scope, fn ->
      team = team_id && (lock_team(scope, team_id) || Repo.rollback(:invalid_team))

      Resource
      |> where([resource], resource.organization_id == ^organization_id)
      |> where([resource], resource.id in ^ids)
      |> order_by([resource], asc: resource.id)
      |> select([resource], resource.id)
      |> Repo.all()
      |> Enum.count(&(put_owner!(scope, &1, team, nil) == :changed))
      |> then(&{:ok, &1})
    end)
  end

  # Writes the owner and its Activity entry. `previous_team` names the team
  # being deleted, whose row is gone from joins by the time Activity reads.
  defp put_owner!(scope, resource_id, team, previous_team) do
    team_id = team && team.id

    case Inventory.put_resource_owner!(scope, resource_id, team_id, "person") do
      {:unchanged, _resource} ->
        :unchanged

      {:changed, before, _after} ->
        before_team =
          previous_team || (before.owner_team_id && Repo.get(Team, before.owner_team_id))

        {:ok, _event} =
          Inventory.create_change_event(scope, %{
            kind: "owner_changed",
            field: "owner_team",
            resource_id: resource_id,
            old_value: team_value(before_team),
            new_value: team_value(team),
            occurred_at: Renga.Time.utc_now_ms()
          })

        :changed
    end
  end

  defp team_value(nil), do: nil
  defp team_value(%Team{id: id, name: name}), do: %{"team_id" => id, "name" => name}

  defp cast_id(id) do
    case Ecto.UUID.cast(id) do
      {:ok, id} -> id
      :error -> nil
    end
  end

  defp lock_team(%Scope{organization_id: organization_id}, id) do
    case cast_id(id) do
      nil ->
        nil

      id ->
        Team
        |> where([team], team.id == ^id and team.organization_id == ^organization_id)
        |> lock("FOR UPDATE")
        |> Repo.one()
    end
  end

  defp lock_team!(scope, id), do: lock_team(scope, id) || Repo.rollback(:not_found)

  defp managed(%Scope{organization_id: organization_id} = scope, mutation) do
    Repo.transaction(fn ->
      authorize_manager!(scope)

      case mutation.() do
        {:ok, result} -> result
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
    |> Changes.broadcast(organization_id)
  end

  defp authorize_manager!(%Scope{
         membership_id: membership_id,
         user: %{id: user_id},
         organization_id: organization_id
       })
       when not is_nil(membership_id) do
    active? =
      Organization
      |> where([organization], organization.id == ^organization_id)
      |> where([organization], organization.status == "active")
      |> lock("FOR UPDATE")
      |> Repo.exists?()

    manager? =
      OrganizationMembership
      |> where([membership], membership.id == ^membership_id)
      |> where([membership], membership.user_id == ^user_id)
      |> where([membership], membership.organization_id == ^organization_id)
      |> where([membership], membership.status == "active")
      |> where([membership], membership.role in ["owner", "admin"])
      |> lock("FOR UPDATE")
      |> Repo.exists?()

    unless active? and manager?, do: Repo.rollback(:forbidden)
  end

  defp authorize_manager!(%Scope{}), do: Repo.rollback(:forbidden)
end
