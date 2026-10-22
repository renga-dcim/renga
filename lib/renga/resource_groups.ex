defmodule Renga.ResourceGroups do
  @moduledoc """
  Resource groups and group sets (RFD 18): named sets of resources that
  people curate, for access boundaries that cut across sites and teams, such
  as environment, customer, or compliance scope.

  Holders of `groups.manage` define groups and sets. Changing who is in a
  group needs `inventory.edit` over every resource whose effective membership
  changes, because conditions read membership as an attribute: RFD 17's
  before-and-after rule applies. Only people change direct membership;
  agents, reconcilers, and triage rules have no path here.

  Effective membership is materialized in `resource_group_memberships`, one
  row per resource, authorization view, and group, rebuilt in the
  transaction that changes its sources. Exclusive sets are enforced on those
  rows for each view: a mutation that would put a resource in two groups of
  one exclusive set is refused as a whole, never resolved by picking a
  winner.

  Every write that can change effective membership takes, in order, the
  organization lock (`Renga.Authorization.authorize!/3`, which stands in for
  RFD 17's authorization-version lock until that exists) and then the
  organization's group-projection lock. Later writers, such as placement
  changes that move a resource into a grouped rack, take the same two locks
  before their own hierarchy or rack locks.

  Until RFD 17 conditions exist every grant covers the whole organization,
  so a single `inventory.edit` check covers every affected resource both
  before and after a change.
  """

  import Ecto.Query, warn: false

  alias Renga.Accounts.Scope
  alias Renga.Authorization
  alias Renga.Inventory
  alias Renga.Inventory.Changes
  alias Renga.Inventory.Resource
  alias Renga.Repo
  alias Renga.ResourceGroups.Group
  alias Renga.ResourceGroups.GroupSet
  alias Renga.ResourceGroups.Member
  alias Renga.ResourceGroups.Membership

  @doc "UI hint: `groups.manage` defines groups and group sets."
  def can_manage?(%Scope{} = scope), do: Authorization.allowed?(scope, "groups.manage")

  @doc "UI hint: `inventory.edit` changes who is in a group."
  def can_change_membership?(%Scope{} = scope),
    do: Authorization.allowed?(scope, "inventory.edit")

  ## Reading

  @doc """
  The group sets the scope can see, by name: every set for managers, and
  otherwise the sets that hold a group the scope can see.
  """
  def list_group_sets(%Scope{organization_id: organization_id} = scope) do
    visible = visible_groups(scope)

    GroupSet
    |> where([set], set.organization_id == ^organization_id)
    |> then(fn query ->
      if can_manage?(scope),
        do: query,
        else: where(query, [set], set.id in subquery(select(visible, [g], g.group_set_id)))
    end)
    |> order_by([set], asc: fragment("lower(?)", set.name))
    |> Repo.all()
  end

  @doc """
  The groups the scope can see, by name, each with its set and its number of
  direct members.
  """
  def list_groups(%Scope{organization_id: organization_id} = scope) do
    members =
      from member in Member,
        where: member.organization_id == ^organization_id,
        group_by: member.group_id,
        select: %{group_id: member.group_id, count: count(member.id)}

    scope
    |> visible_groups()
    |> join(:left, [group], members in subquery(members), on: members.group_id == group.id)
    |> order_by([group], asc: fragment("lower(?)", group.name))
    |> select([group, members], %{group | member_count: coalesce(members.count, 0)})
    |> preload(:group_set)
    |> Repo.all()
  end

  @doc "Fetches a group the scope can see, with its set, or nil (ids often come from a URL)."
  def get_group(%Scope{} = scope, id) do
    case Ecto.UUID.cast(id || "") do
      {:ok, id} ->
        scope
        |> visible_groups()
        |> where([group], group.id == ^id)
        |> preload(:group_set)
        |> Repo.one()

      :error ->
        nil
    end
  end

  @doc "Fetches a group set the scope can see, or nil."
  def get_group_set(%Scope{} = scope, id) do
    case Ecto.UUID.cast(id || "") do
      {:ok, id} -> scope |> list_group_sets() |> Enum.find(&(&1.id == id))
      :error -> nil
    end
  end

  @doc "A group's direct members, as resources by name."
  def list_members(%Scope{organization_id: organization_id}, %Group{id: group_id}) do
    Resource
    |> join(:inner, [resource], member in Member, on: member.resource_id == resource.id)
    |> where([resource, member], member.organization_id == ^organization_id)
    |> where([resource, member], member.group_id == ^group_id)
    |> order_by([resource], asc: fragment("lower(?)", resource.name), asc: resource.id)
    |> Repo.all()
  end

  @doc """
  The groups a resource is effectively in that the scope can see, by name,
  with where each membership comes from:

    * `:direct` - whether a person put the resource itself in the group
    * `:trusted` - whether the membership holds in the trusted view, which
      `inventory.read` and operational permissions use; when false it comes
      only through placement nobody has confirmed
    * `:via` - the containers that pass the group down, each with its id,
      name, kind, and whether every edge to it was set or confirmed by a
      person
  """
  def list_resource_groups(%Scope{organization_id: organization_id} = scope, resource_id) do
    views =
      scope
      |> visible_groups()
      |> join(:inner, [group], membership in Membership, on: membership.group_id == group.id)
      |> where([_group, membership], membership.resource_id == ^resource_id)
      |> select([group, membership], {group, membership.view})
      |> Repo.all()
      |> Enum.group_by(fn {group, _view} -> group end, fn {_group, view} -> view end)

    direct =
      Member
      |> where([member], member.organization_id == ^organization_id)
      |> where([member], member.resource_id == ^resource_id)
      |> select([member], member.group_id)
      |> Repo.all()
      |> MapSet.new()

    via = container_paths(organization_id, resource_id)

    views
    |> Enum.sort_by(fn {group, _views} -> String.downcase(group.name) end)
    |> Enum.map(fn {group, views} ->
      %{
        group: Repo.preload(group, :group_set),
        direct: MapSet.member?(direct, group.id),
        trusted: "trusted" in views,
        via: Map.get(via, group.id, [])
      }
    end)
  end

  # RFD 18: a person sees a group when they manage groups, hold an
  # assignment that names it, or can read one of its members. Conditions
  # cannot name a group yet, and reads are not yet scoped, so for everyone
  # else a group is visible when `inventory.read` covers it and it has a
  # trusted member. Observed placement never reveals a group's name.
  defp visible_groups(%Scope{organization_id: organization_id} = scope) do
    query = from(group in Group, as: :group, where: group.organization_id == ^organization_id)

    cond do
      can_manage?(scope) ->
        query

      Authorization.allowed?(scope, "inventory.read") ->
        where(
          query,
          [group],
          exists(
            from membership in Membership,
              where: membership.group_id == parent_as(:group).id and membership.view == "trusted"
          )
        )

      true ->
        where(query, false)
    end
  end

  @doc "A changeset for the group form."
  def change_group(%Group{} = group, attrs \\ %{}), do: Group.changeset(group, attrs)

  @doc "A changeset for the group set form."
  def change_group_set(%GroupSet{} = set, attrs \\ %{}), do: GroupSet.changeset(set, attrs)

  ## Group sets

  @doc "Creates a group set. Needs `groups.manage`."
  def create_group_set(%Scope{organization_id: organization_id} = scope, attrs) do
    managed(scope, "groups.manage", fn ->
      with {:ok, set} <-
             %GroupSet{organization_id: organization_id}
             |> GroupSet.changeset(attrs)
             |> Repo.insert() do
        record!(scope, "group_set_created", %{new_value: set_value(set)})
        {:ok, set}
      end
    end)
  end

  @doc """
  Renames, re-describes, or changes the exclusivity of a group set. Needs
  `groups.manage`. Making a set exclusive is refused with
  `{:exclusive_conflict, conflicts}` while any resource is in two of its
  groups.
  """
  def update_group_set(%Scope{} = scope, %GroupSet{} = set, attrs) do
    managed(scope, "groups.manage", fn ->
      before = lock_group_set!(scope, set.id)

      with {:ok, set} <- before |> GroupSet.changeset(attrs) |> Repo.update() do
        reproject_set!(scope, before, set)

        record!(scope, "group_set_updated", %{
          old_value: set_value(before),
          new_value: set_value(set)
        })

        {:ok, set}
      end
    end)
  end

  @doc """
  Deletes a group set. Its groups stay, outside any set, with their members.
  Needs `groups.manage`.
  """
  def delete_group_set(%Scope{} = scope, %GroupSet{} = set) do
    managed(scope, "groups.manage", fn ->
      set = lock_group_set!(scope, set.id)
      {:ok, deleted} = Repo.delete(set)
      record!(scope, "group_set_deleted", %{old_value: set_value(set)})
      {:ok, deleted}
    end)
  end

  ## Groups

  @doc "Creates a group, optionally in a set. Needs `groups.manage`."
  def create_group(%Scope{organization_id: organization_id} = scope, attrs) do
    managed(scope, "groups.manage", fn ->
      with {:ok, group} <-
             %Group{organization_id: organization_id}
             |> Group.changeset(attrs)
             |> Repo.insert() do
        group = Repo.preload(group, :group_set)

        record!(scope, "group_created", %{
          metadata: %{"group_id" => group.id},
          new_value: group_value(group)
        })

        {:ok, group}
      end
    end)
  end

  @doc """
  Renames, re-describes, or moves a group between sets. Needs
  `groups.manage`. Moving a group into an exclusive set is refused with
  `{:exclusive_conflict, conflicts}` when one of its members is already in
  another group of that set.
  """
  def update_group(%Scope{} = scope, %Group{} = group, attrs) do
    managed(scope, "groups.manage", fn ->
      before = scope |> lock_group!(group.id) |> Repo.preload(:group_set)

      with {:ok, group} <- before |> Group.changeset(attrs) |> Repo.update() do
        group = Repo.preload(group, :group_set, force: true)

        reproject_group!(scope, before, group)

        record!(scope, "group_updated", %{
          metadata: %{"group_id" => group.id},
          old_value: group_value(before),
          new_value: group_value(group)
        })

        {:ok, group}
      end
    end)
  end

  @doc """
  Deletes a group. Each of its direct members leaves it, recorded on the
  resource. Needs `groups.manage`, and also `inventory.edit` when the group
  has members because deletion changes their membership.
  """
  def delete_group(%Scope{} = scope, %Group{} = group) do
    managed(scope, "groups.manage", fn ->
      group = lock_group!(scope, group.id)
      members = members_of_group(scope, group.id)

      if members != [], do: Authorization.authorize!(scope, "inventory.edit")

      Enum.each(members, fn resource_id ->
        record!(scope, "group_member_removed", %{
          resource_id: resource_id,
          metadata: %{"group_id" => group.id, "reason" => "group_deleted"},
          old_value: group_value(group)
        })
      end)

      {:ok, deleted} = Repo.delete(group)

      record!(scope, "group_deleted", %{
        metadata: %{"group_id" => group.id, "members" => length(members)},
        old_value: group_value(group)
      })

      {:ok, deleted}
    end)
  end

  # Exclusivity applies to a set's members only once a change makes it so.
  defp reproject_set!(_scope, %{exclusive: same}, %{exclusive: same}), do: :ok
  defp reproject_set!(scope, _before, set), do: project!(scope, members_of_set(scope, set.id))

  defp reproject_group!(_scope, %{group_set_id: same}, %{group_set_id: same}), do: :ok

  defp reproject_group!(scope, _before, group),
    do: project!(scope, members_of_group(scope, group.id))

  ## Membership

  @doc """
  Puts resources in a group directly. Needs `inventory.edit` over every
  resource. The whole change is refused when any id is not a resource in
  the organization, or with `{:exclusive_conflict, conflicts}` when it would
  put a resource in two groups of an exclusive set. Returns
  `{:ok, added_count}`; resources already in the group are left alone.
  """
  def add_members(%Scope{} = scope, %Group{} = group, resource_ids, opts \\ []) do
    managed(scope, "inventory.edit", fn ->
      group = lock_group!(scope, group.id)
      resource_ids = resources!(scope, resource_ids)
      added = insert_members!(scope, group, resource_ids, opts)
      project!(scope, added)
      {:ok, length(added)}
    end)
  end

  @doc """
  Takes resources out of a group. Needs `inventory.edit` over every
  resource. Returns `{:ok, removed_count}`.
  """
  def remove_members(%Scope{} = scope, %Group{} = group, resource_ids, opts \\ []) do
    managed(scope, "inventory.edit", fn ->
      group = lock_group!(scope, group.id)
      resource_ids = resources!(scope, resource_ids)
      removed = delete_members!(scope, group, resource_ids, opts)
      project!(scope, removed)
      {:ok, length(removed)}
    end)
  end

  @doc """
  Moves a resource into `group` and out of every other group in the same
  set, as one change. Needs `inventory.edit` over the resource. This is how
  a resource changes groups within an exclusive set.
  """
  def move_member(%Scope{} = scope, resource_id, %Group{} = group, opts \\ []) do
    managed(scope, "inventory.edit", fn ->
      group = lock_group!(scope, group.id)
      group.group_set_id || Repo.rollback(:not_in_set)
      [resource_id] = resources!(scope, [resource_id])

      siblings =
        Group
        |> where([sibling], sibling.organization_id == ^scope.organization_id)
        |> where([sibling], sibling.group_set_id == ^group.group_set_id)
        |> where([sibling], sibling.id != ^group.id)
        |> order_by([sibling], asc: sibling.id)
        |> lock("FOR UPDATE")
        |> Repo.all()

      removed = Enum.flat_map(siblings, &delete_members!(scope, &1, [resource_id], opts))
      added = insert_members!(scope, group, [resource_id], opts)
      project!(scope, Enum.uniq(removed ++ added))

      {:ok, if(removed == [] and added == [], do: :unchanged, else: :moved)}
    end)
  end

  defp insert_members!(scope, group, resource_ids, opts) do
    now = Renga.Time.utc_now_ms()

    rows =
      Enum.map(resource_ids, fn resource_id ->
        %{
          id: Ecto.UUID.generate(),
          organization_id: scope.organization_id,
          group_id: group.id,
          resource_id: resource_id,
          added_by_user_id: scope.user.id,
          inserted_at: now
        }
      end)

    {_count, added} =
      Repo.insert_all(Member, rows,
        on_conflict: :nothing,
        conflict_target: [:group_id, :resource_id],
        returning: [:resource_id]
      )

    added = Enum.map(added, & &1.resource_id)

    Enum.each(added, fn resource_id ->
      record!(scope, "group_member_added", %{
        resource_id: resource_id,
        metadata: membership_metadata(group, opts),
        new_value: group_value(group)
      })
    end)

    added
  end

  defp delete_members!(scope, group, resource_ids, opts) do
    {_count, removed} =
      Member
      |> where([member], member.organization_id == ^scope.organization_id)
      |> where([member], member.group_id == ^group.id)
      |> where([member], member.resource_id in ^resource_ids)
      |> select([member], member.resource_id)
      |> Repo.delete_all()

    Enum.each(removed, fn resource_id ->
      record!(scope, "group_member_removed", %{
        resource_id: resource_id,
        metadata: membership_metadata(group, opts),
        old_value: group_value(group)
      })
    end)

    removed
  end

  defp membership_metadata(group, opts) do
    case Keyword.get(opts, :reason) do
      reason when is_binary(reason) and reason != "" ->
        %{"group_id" => group.id, "reason" => reason}

      _none ->
        %{"group_id" => group.id}
    end
  end

  # Every id must name a resource in the organization; a bulk change is
  # refused as a whole rather than applied to the part that resolved.
  defp resources!(%Scope{organization_id: organization_id}, ids) do
    ids =
      ids
      |> Enum.map(fn id ->
        case Ecto.UUID.cast(id) do
          {:ok, id} -> id
          :error -> Repo.rollback(:not_found)
        end
      end)
      |> Enum.uniq()

    found =
      Resource
      |> where([resource], resource.organization_id == ^organization_id)
      |> where([resource], resource.id in ^ids)
      |> select([resource], resource.id)
      |> Repo.all()

    if length(found) == length(ids), do: ids, else: Repo.rollback(:not_found)
  end

  defp members_of_group(%Scope{organization_id: organization_id}, group_id) do
    Member
    |> where([member], member.organization_id == ^organization_id)
    |> where([member], member.group_id == ^group_id)
    |> select([member], member.resource_id)
    |> Repo.all()
  end

  defp members_of_set(%Scope{organization_id: organization_id}, set_id) do
    Member
    |> join(:inner, [member], group in Group, on: group.id == member.group_id)
    |> where([member], member.organization_id == ^organization_id)
    |> where([_member, group], group.group_set_id == ^set_id)
    |> distinct(true)
    |> select([member], member.resource_id)
    |> Repo.all()
  end

  ## Projection

  # Containment edges from a resource to the container resource that holds
  # it, and whether a person set or confirmed the edge. A resource's current
  # placement names its site, location, and rack, and is trusted only once
  # confirmed; racks and locations sit in their location and site, which
  # only people edit. The location hierarchy is acyclic (`Renga.DCIM`
  # refuses cycles), so walking the edges ends.
  @edges """
  SELECT placement.resource_id AS child, site.resource_id AS parent,
         placement.confirmed AS trusted
    FROM current_placements AS placement
    JOIN sites AS site ON site.id = placement.site_id
   WHERE placement.organization_id = $1
  UNION ALL
  SELECT placement.resource_id, location.resource_id, placement.confirmed
    FROM current_placements AS placement
    JOIN locations AS location ON location.id = placement.location_id
   WHERE placement.organization_id = $1
  UNION ALL
  SELECT placement.resource_id, rack.resource_id, placement.confirmed
    FROM current_placements AS placement
    JOIN racks AS rack ON rack.id = placement.rack_id
   WHERE placement.organization_id = $1
  UNION ALL
  SELECT rack.resource_id, site.resource_id, true
    FROM racks AS rack
    JOIN sites AS site ON site.id = rack.site_id
   WHERE rack.organization_id = $1
  UNION ALL
  SELECT rack.resource_id, location.resource_id, true
    FROM racks AS rack
    JOIN locations AS location ON location.id = rack.location_id
   WHERE rack.organization_id = $1
  UNION ALL
  SELECT location.resource_id, site.resource_id, true
    FROM locations AS location
    JOIN sites AS site ON site.id = location.site_id
   WHERE location.organization_id = $1
  UNION ALL
  SELECT location.resource_id, parent.resource_id, true
    FROM locations AS location
    JOIN locations AS parent ON parent.id = location.parent_id
   WHERE location.organization_id = $1
  """

  # Every container above each resource in $2, and whether the whole path
  # to it was set or confirmed by people.
  @reach """
  reach(resource_id, container_id, trusted) AS (
    SELECT edge.child, edge.parent, edge.trusted FROM edges AS edge WHERE edge.child = ANY($2)
    UNION
    SELECT reach.resource_id, edge.parent, reach.trusted AND edge.trusted
      FROM reach JOIN edges AS edge ON edge.child = reach.container_id
  )
  """

  # The effective memberships of the resources in $2, as candidate rows.
  # The inventory view takes a resource's own direct memberships and those
  # of every container above it; the trusted view takes only containers
  # reached through edges people set or confirmed.
  @candidates """
  WITH RECURSIVE edges AS (#{@edges}),
  #{@reach},
  sources(resource_id, member_id, view) AS (
    SELECT id, id, view.view
      FROM unnest($2::uuid[]) AS id
     CROSS JOIN (VALUES ('inventory'), ('trusted')) AS view(view)
    UNION
    SELECT resource_id, container_id, 'inventory' FROM reach
    UNION
    SELECT resource_id, container_id, 'trusted' FROM reach WHERE trusted
  ),
  candidates AS (
    SELECT DISTINCT $1::uuid AS organization_id, source.resource_id, source.view,
           member.group_id,
           CASE WHEN group_set.exclusive THEN group_set.id END AS group_set_id
      FROM sources AS source
      JOIN resource_group_members AS member
        ON member.organization_id = $1 AND member.resource_id = source.member_id
      JOIN resource_groups AS grp ON grp.id = member.group_id
      LEFT JOIN resource_group_sets AS group_set ON group_set.id = grp.group_set_id
  )
  """

  # The resources in $2 and every resource placed or contained below them,
  # through any edge: their effective membership follows a container's.
  @affected """
  WITH RECURSIVE edges AS (#{@edges}),
  below(resource_id) AS (
    SELECT unnest($2::uuid[])
    UNION
    SELECT edge.child FROM below JOIN edges AS edge ON edge.parent = below.resource_id
  )
  SELECT resource_id FROM below
  """

  defp project!(%Scope{organization_id: organization_id}, resource_ids),
    do: reproject!(organization_id, resource_ids)

  @doc false
  # Rebuilds the effective-membership rows of `resource_ids` and of every
  # resource below them from their sources, refusing the whole mutation
  # when a resource would be in two groups of one exclusive set in either
  # view. Every writer that changes direct membership, current placement,
  # or the location and rack hierarchy calls this in its transaction, after
  # `lock_projection!/1`, so the check and the write see the same sources;
  # the partial unique index is the backstop.
  def reproject!(_organization_id, []), do: :ok

  def reproject!(organization_id, resource_ids) do
    organization = Ecto.UUID.dump!(organization_id)

    # Without any direct member there is nothing to inherit or remove, so
    # placement writes in organizations that use no groups stay cheap.
    if Repo.exists?(where(Member, [member], member.organization_id == ^organization_id)) or
         Repo.exists?(where(Membership, [row], row.organization_id == ^organization_id)) do
      %{rows: affected} =
        Repo.query!(@affected, [organization, Enum.map(resource_ids, &Ecto.UUID.dump!/1)])

      params = [organization, List.flatten(affected)]

      %{rows: conflicts} =
        Repo.query!(
          """
          #{@candidates}
          SELECT resource_id, group_set_id, array_agg(DISTINCT group_id)
            FROM candidates
           WHERE group_set_id IS NOT NULL
           GROUP BY resource_id, view, group_set_id
          HAVING count(DISTINCT group_id) > 1
          """,
          params
        )

      if conflicts != [] do
        Repo.rollback({:exclusive_conflict, describe_conflicts(organization_id, conflicts)})
      end

      Repo.query!(
        "DELETE FROM resource_group_memberships WHERE organization_id = $1 AND resource_id = ANY($2)",
        params
      )

      Repo.query!(
        """
        #{@candidates}
        INSERT INTO resource_group_memberships
          (organization_id, resource_id, view, group_id, group_set_id)
        SELECT organization_id, resource_id, view, group_id, group_set_id FROM candidates
        """,
        params
      )
    end

    :ok
  end

  # The containers above `resource_id` that are direct members of a group,
  # by group, nearest trust first.
  defp container_paths(organization_id, resource_id) do
    %{rows: rows} =
      Repo.query!(
        """
        WITH RECURSIVE edges AS (#{@edges}),
        #{@reach}
        SELECT member.group_id, container.id, container.name, container.kind,
               bool_or(reach.trusted)
          FROM reach
          JOIN resource_group_members AS member
            ON member.organization_id = $1 AND member.resource_id = reach.container_id
          JOIN resources AS container ON container.id = reach.container_id
         GROUP BY member.group_id, container.id, container.name, container.kind
        """,
        [Ecto.UUID.dump!(organization_id), [Ecto.UUID.dump!(resource_id)]]
      )

    rows
    |> Enum.map(fn [group_id, id, name, kind, trusted] ->
      {Ecto.UUID.load!(group_id),
       %{id: Ecto.UUID.load!(id), name: name, kind: kind, trusted: trusted}}
    end)
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
    |> Map.new(fn {group_id, containers} ->
      {group_id, Enum.sort_by(containers, &{not &1.trusted, &1.name})}
    end)
  end

  # Names each conflict once, whichever views it appears in, so the refusal
  # can say "web-01 would be in both Production and Staging".
  defp describe_conflicts(organization_id, rows) do
    rows =
      rows
      |> Enum.map(fn [resource_id, set_id, group_ids] ->
        {Ecto.UUID.load!(resource_id), Ecto.UUID.load!(set_id),
         group_ids |> Enum.map(&Ecto.UUID.load!/1) |> Enum.sort()}
      end)
      |> Enum.uniq()

    names = fn schema, ids ->
      schema
      |> where([row], row.organization_id == ^organization_id and row.id in ^ids)
      |> select([row], {row.id, row.name})
      |> Repo.all()
      |> Map.new()
    end

    resources = names.(Resource, Enum.map(rows, &elem(&1, 0)))
    sets = names.(GroupSet, Enum.map(rows, &elem(&1, 1)))
    groups = names.(Group, Enum.flat_map(rows, &elem(&1, 2)))

    Enum.map(rows, fn {resource_id, set_id, group_ids} ->
      %{
        resource_id: resource_id,
        resource: resources[resource_id],
        group_set: sets[set_id],
        groups: group_ids |> Enum.map(&groups[&1]) |> Enum.sort()
      }
    end)
  end

  @doc false
  # Serializes every write that can change an organization's effective group
  # membership. Taken after the organization lock and before any hierarchy
  # or rack lock.
  def lock_projection!(organization_id) do
    Repo.query!("SELECT pg_advisory_xact_lock(hashtext($1), hashtext($2))", [
      "renga.resource_groups.projection",
      organization_id
    ])

    :ok
  end

  ## Helpers

  defp lock_group!(%Scope{organization_id: organization_id}, id) do
    Group
    |> where([group], group.id == ^id and group.organization_id == ^organization_id)
    |> lock("FOR UPDATE")
    |> Repo.one() || Repo.rollback(:not_found)
  end

  defp lock_group_set!(%Scope{organization_id: organization_id}, id) do
    GroupSet
    |> where([set], set.id == ^id and set.organization_id == ^organization_id)
    |> lock("FOR UPDATE")
    |> Repo.one() || Repo.rollback(:not_found)
  end

  defp record!(scope, kind, attrs) do
    {:ok, _event} =
      Inventory.create_change_event(
        scope,
        Map.merge(%{kind: kind, field: "group", occurred_at: Renga.Time.utc_now_ms()}, attrs)
      )
  end

  defp group_value(%Group{} = group) do
    set =
      case group.group_set do
        %GroupSet{name: name} -> name
        _not_loaded_or_none -> nil
      end

    %{"group_id" => group.id, "name" => group.name, "group_set" => set}
  end

  defp set_value(%GroupSet{} = set),
    do: %{"group_set_id" => set.id, "name" => set.name, "exclusive" => set.exclusive}

  defp managed(%Scope{organization_id: organization_id} = scope, permission, mutation) do
    Repo.transaction(fn ->
      Authorization.authorize!(scope, permission)
      lock_projection!(organization_id)

      case mutation.() do
        {:ok, result} -> result
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
    |> Changes.broadcast(organization_id)
  end
end
