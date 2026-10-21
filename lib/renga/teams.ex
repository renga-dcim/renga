defmodule Renga.Teams do
  @moduledoc """
  Teams and the resources they own (RFD 8, "Triage").

  Holders of `teams.manage` manage teams, who is on them, and owners;
  members request an owner change through `Renga.Requests`. Every owner change is a resource revision
  and an Activity entry with its actor. A team can be deleted while it owns
  resources: they become unowned, each with its own Activity entry, and so
  return to triage.
  """

  import Ecto.Query, warn: false

  alias Renga.Accounts.OrganizationMembership
  alias Renga.Accounts.Scope
  alias Renga.Authorization
  alias Renga.Inventory
  alias Renga.Inventory.Changes
  alias Renga.Inventory.Resource
  alias Renga.Repo
  alias Renga.Teams.Team
  alias Renga.Teams.TeamMembership

  @doc "UI hint: `teams.manage` covers teams and resource owners."
  def can_manage?(%Scope{} = scope), do: Authorization.allowed?(scope, "teams.manage")

  ## Teams

  @doc """
  The organization's teams by name, each with the number of resources it
  owns and of people on it.
  """
  def list_teams(%Scope{organization_id: organization_id}) do
    owned =
      from resource in Resource,
        where:
          resource.organization_id == ^organization_id and not is_nil(resource.owner_team_id),
        group_by: resource.owner_team_id,
        select: %{team_id: resource.owner_team_id, count: count(resource.id)}

    people =
      from member in TeamMembership,
        where: member.organization_id == ^organization_id,
        group_by: member.team_id,
        select: %{team_id: member.team_id, count: count(member.id)}

    Team
    |> where([team], team.organization_id == ^organization_id)
    |> join(:left, [team], owned in subquery(owned), on: owned.team_id == team.id)
    |> join(:left, [team], people in subquery(people), on: people.team_id == team.id)
    |> order_by([team], asc: fragment("lower(?)", team.name))
    |> select([team, owned, people], %{
      team
      | resource_count: coalesce(owned.count, 0),
        member_count: coalesce(people.count, 0)
    })
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

  ## Members

  @doc "The people on a team, as organization memberships with users, by email."
  def list_team_members(%Scope{organization_id: organization_id}, %Team{id: team_id}) do
    OrganizationMembership
    |> join(:inner, [membership], team_member in TeamMembership,
      on: team_member.membership_id == membership.id
    )
    |> join(:inner, [membership], user in assoc(membership, :user))
    |> where([_membership, team_member], team_member.organization_id == ^organization_id)
    |> where([_membership, team_member], team_member.team_id == ^team_id)
    |> order_by([_membership, _team_member, user], asc: user.email)
    |> preload([_membership, _team_member, user], user: user)
    |> Repo.all()
  end

  @doc """
  Puts an active member of the organization on a team, recorded in
  Activity. Needs `teams.manage`. Adding someone already on it changes
  nothing.

  Team membership is a grant transition in RFD 17: once assignments can be
  conditioned on `$subject_teams`, this is where the actor's grant ceiling
  must also cover what the person gains. No assignment can name a team yet,
  so joining one grants nothing today.
  """
  def add_member(%Scope{} = scope, %Team{} = team, membership_id) do
    managed(scope, fn ->
      team = lock_team!(scope, team.id)
      membership = lock_membership!(scope, membership_id)

      # The team lock serializes changes to its members.
      if on_team?(team, membership) do
        {:ok, :unchanged}
      else
        Repo.insert!(%TeamMembership{
          organization_id: scope.organization_id,
          team_id: team.id,
          membership_id: membership.id,
          added_by_user_id: scope.user.id
        })

        record_team_member!(scope, "team_member_added", team, membership)
        {:ok, :added}
      end
    end)
  end

  defp on_team?(team, membership) do
    TeamMembership
    |> where([team_member], team_member.team_id == ^team.id)
    |> where([team_member], team_member.membership_id == ^membership.id)
    |> Repo.exists?()
  end

  @doc "Takes a person off a team, recorded in Activity. Needs `teams.manage`."
  def remove_member(%Scope{} = scope, %Team{} = team, membership_id) do
    managed(scope, fn ->
      team = lock_team!(scope, team.id)

      with id when is_binary(id) <- cast_id(membership_id),
           {1, _deleted} <-
             TeamMembership
             |> where([team_member], team_member.organization_id == ^scope.organization_id)
             |> where([team_member], team_member.team_id == ^team.id)
             |> where([team_member], team_member.membership_id == ^id)
             |> Repo.delete_all() do
        membership = OrganizationMembership |> Repo.get!(id) |> Repo.preload(:user)
        record_team_member!(scope, "team_member_removed", team, membership)
        {:ok, :removed}
      else
        _not_on_team -> {:ok, :unchanged}
      end
    end)
  end

  defp lock_membership!(%Scope{organization_id: organization_id}, id) do
    with id when is_binary(id) <- cast_id(id),
         %OrganizationMembership{} = membership <-
           OrganizationMembership
           |> where([membership], membership.organization_id == ^organization_id)
           |> where([membership], membership.id == ^id and membership.status == "active")
           |> lock("FOR UPDATE")
           |> Repo.one() do
      Repo.preload(membership, :user)
    else
      _missing_or_disabled -> Repo.rollback(:invalid_member)
    end
  end

  defp record_team_member!(scope, kind, team, membership) do
    {:ok, _event} =
      Inventory.create_change_event(scope, %{
        kind: kind,
        field: "team",
        new_value: team_value(team),
        metadata: %{"member" => membership.user.email, "membership_id" => membership.id},
        occurred_at: Renga.Time.utc_now_ms()
      })
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

  defp authorize_manager!(%Scope{} = scope),
    do: Authorization.authorize!(scope, "teams.manage")
end
