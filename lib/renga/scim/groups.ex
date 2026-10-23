defmodule Renga.Scim.Groups do
  @moduledoc """
  A connection's directory groups (RFD 16, "Directory entries"): the SCIM
  `Groups` resource. Members are directory entries of the same connection;
  a write naming any other id is `invalidValue` and changes nothing.

  Like user writes, group writes take the organization lock, since a
  group's members decide mapped roles, and every change is an Activity
  entry with the connection, token, and request ID.
  """

  import Ecto.Query, warn: false

  alias Renga.Authorization
  alias Renga.Inventory.ChangeEvent
  alias Renga.Repo
  alias Renga.Scim.Client
  alias Renga.Scim.Connection
  alias Renga.Scim.DirectoryGroup
  alias Renga.Scim.DirectoryUser
  alias Renga.Scim.Filter
  alias Renga.Scim.GroupMember
  alias Renga.Scim.GroupResource

  @filters %{"id" => :id, "displayName" => :display_name, "externalId" => :external_id}

  @doc "A group of the connection by SCIM id, with its members, or nil."
  def get(%Connection{id: connection_id}, id) do
    case Ecto.UUID.cast(id || "") do
      {:ok, id} ->
        DirectoryGroup
        |> where([group], group.connection_id == ^connection_id and group.id == ^id)
        |> preload(members: ^members_query())
        |> Repo.one()

      :error ->
        nil
    end
  end

  @doc """
  One page of the connection's groups, oldest first, and how many match.
  `opts` may set `members: false` to skip loading members, as Entra asks
  with `excludedAttributes=members`.
  """
  def list(%Connection{id: connection_id}, filter, start_index, count, opts \\ []) do
    with {:ok, query} <- filtered(where(DirectoryGroup, connection_id: ^connection_id), filter) do
      total = Repo.aggregate(query, :count)

      groups =
        query
        |> order_by([group], asc: group.inserted_at, asc: group.id)
        |> offset(^(start_index - 1))
        |> limit(^count)
        |> then(
          &if(Keyword.get(opts, :members, true),
            do: preload(&1, members: ^members_query()),
            else: &1
          )
        )
        |> Repo.all()

      {:ok, {total, groups}}
    end
  end

  @doc "Creates a group from a SCIM Group resource."
  def create(%Client{connection: connection} = client, resource) do
    write(client, fn ->
      with {:ok, attrs, member_ids} <- GroupResource.create(resource),
           {:ok, members} <- members(connection, member_ids),
           {:ok, group} <-
             %DirectoryGroup{
               organization_id: connection.organization_id,
               connection_id: connection.id
             }
             |> DirectoryGroup.changeset(attrs)
             |> Repo.insert()
             |> invalid() do
        {added, _removed} = set_members!(group, MapSet.new(), members)
        record!(client, "scim_group_created", group, added, [])
        {:ok, reload(group)}
      end
    end)
  end

  @doc "Replaces a group's name and whole member set (PUT)."
  def replace(%Client{connection: connection} = client, id, resource) do
    write(client, fn ->
      with {:ok, group} <- lock_group(connection, id),
           {:ok, attrs, member_ids} <- GroupResource.replace(resource),
           {:ok, members} <- members(connection, member_ids) do
        change(client, group, attrs, members)
      end
    end)
  end

  @doc "Applies SCIM PATCH operations to a group."
  def patch(%Client{connection: connection} = client, id, operations) do
    write(client, fn ->
      with {:ok, group} <- lock_group(connection, id),
           current = current_member_ids(group),
           attrs = Map.take(group, [:display_name, :external_id]),
           {:ok, attrs, member_ids} <- GroupResource.patch(operations, attrs, current),
           {:ok, members} <- members(connection, member_ids, MapSet.new(current)) do
        change(client, group, attrs, members)
      end
    end)
  end

  @doc "Deletes a group and its memberships. A recreated group gets a new id."
  def delete(%Client{connection: connection} = client, id) do
    write(client, fn ->
      with {:ok, group} <- lock_group(connection, id) do
        removed = current_member_ids(group)
        Repo.delete!(group)
        record!(client, "scim_group_deleted", group, [], removed)
        {:ok, group}
      end
    end)
  end

  defp change(client, group, attrs, members) do
    current = group |> current_member_ids() |> MapSet.new()

    with {:ok, updated} <- group |> DirectoryGroup.changeset(attrs) |> Repo.update() |> invalid() do
      {added, removed} = set_members!(updated, current, members)
      record!(client, "scim_group_updated", updated, added, removed)
      {:ok, reload(updated)}
    end
  end

  defp write(%Client{connection: connection}, mutation) do
    Repo.transaction(fn ->
      Authorization.lock_active_organization!(connection.organization_id)

      case mutation.() do
        {:ok, result} -> result
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  defp lock_group(%Connection{id: connection_id}, id) do
    with {:ok, id} <- Ecto.UUID.cast(id || ""),
         %DirectoryGroup{} = group <-
           DirectoryGroup
           |> where([group], group.connection_id == ^connection_id and group.id == ^id)
           |> lock("FOR UPDATE")
           |> Repo.one() do
      {:ok, group}
    else
      _missing -> {:error, :not_found}
    end
  end

  # Every id must be an entry of the connection. `known` ids are already
  # members, so a PATCH that leaves them alone need not look them up again.
  defp members(connection, ids, known \\ MapSet.new()) do
    {known_ids, others} = Enum.split_with(ids, &MapSet.member?(known, &1))

    with {:ok, uuids} <- cast_all(others) do
      found =
        DirectoryUser
        |> where([user], user.connection_id == ^connection.id and user.id in ^uuids)
        |> select([user], user.id)
        |> Repo.all()

      if length(found) == length(Enum.uniq(uuids)),
        do: {:ok, MapSet.new(known_ids ++ found)},
        else: {:error, {:invalid_value, "Every member must be a user of this connection"}}
    end
  end

  defp cast_all(ids) do
    Enum.reduce_while(ids, {:ok, []}, fn id, {:ok, acc} ->
      case Ecto.UUID.cast(id) do
        {:ok, uuid} ->
          {:cont, {:ok, [uuid | acc]}}

        :error ->
          {:halt, {:error, {:invalid_value, "Every member must be a user of this connection"}}}
      end
    end)
  end

  defp set_members!(group, current, wanted) do
    added = wanted |> MapSet.difference(current) |> MapSet.to_list()
    removed = current |> MapSet.difference(wanted) |> MapSet.to_list()

    if removed != [] do
      GroupMember
      |> where([member], member.group_id == ^group.id and member.user_id in ^removed)
      |> Repo.delete_all()
    end

    if added != [] do
      Repo.insert_all(
        GroupMember,
        Enum.map(added, &%{connection_id: group.connection_id, group_id: group.id, user_id: &1})
      )
    end

    {added, removed}
  end

  defp current_member_ids(group) do
    GroupMember
    |> where([member], member.group_id == ^group.id)
    |> select([member], member.user_id)
    |> Repo.all()
  end

  defp reload(group), do: Repo.preload(group, [members: members_query()], force: true)

  defp members_query, do: order_by(DirectoryUser, [user], asc: user.user_name)

  defp invalid({:ok, group}), do: {:ok, group}

  defp invalid({:error, changeset}) do
    {field, {message, opts}} = hd(changeset.errors)
    name = if field == :display_name, do: "displayName", else: "externalId"
    {:error, {:invalid_value, "#{name} #{interpolate(message, opts)}"}}
  end

  # Ecto keeps messages as templates such as "should be at most %{count}
  # character(s)"; a SCIM detail is read as is.
  defp interpolate(message, opts) do
    Regex.replace(~r/%{(\w+)}/, message, fn match, key ->
      opts |> Keyword.get(String.to_existing_atom(key), match) |> to_string()
    end)
  end

  defp filtered(query, nil), do: {:ok, query}

  defp filtered(query, filter) do
    case Filter.parse(filter, @filters) do
      {:ok, {:id, value}} ->
        case Ecto.UUID.cast(value) do
          {:ok, id} -> {:ok, where(query, [group], group.id == ^id)}
          :error -> {:ok, where(query, false)}
        end

      {:ok, {:display_name, value}} ->
        {:ok,
         where(
           query,
           [group],
           fragment("lower(?)", group.display_name) == ^String.downcase(value)
         )}

      {:ok, {:external_id, value}} ->
        {:ok, where(query, [group], group.external_id == ^value)}

      {:error, detail} ->
        {:error, {:invalid_filter, detail}}
    end
  end

  defp record!(%Client{connection: connection} = client, kind, group, added, removed) do
    %ChangeEvent{organization_id: connection.organization_id}
    |> ChangeEvent.changeset(%{
      kind: kind,
      metadata: %{
        "connection_id" => connection.id,
        "token_id" => client.token_id,
        "request_id" => client.request_id,
        "scim_group_id" => group.id,
        "group" => group.display_name,
        "members_added" => added,
        "members_removed" => removed
      },
      occurred_at: Renga.Time.utc_now_ms()
    })
    |> Repo.insert!()
  end
end
