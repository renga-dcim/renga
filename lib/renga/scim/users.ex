defmodule Renga.Scim.Users do
  @moduledoc """
  A connection's directory entries for users (RFD 16, "Directory entries"):
  the SCIM `Users` resource. Every read and write is confined to one
  connection, which `Renga.Scim.Client` names.

  Writes take the organization lock, like every authorization-changing
  write, because an entry's changes decide its membership grant. `userName`
  and a nonempty `externalId` are each unique in the connection; a clash is
  `{:error, {:uniqueness, detail}}`. Every change is an Activity entry with
  the connection, token, and request ID, never the request body.
  """

  import Ecto.Query, warn: false

  alias Renga.Authorization
  alias Renga.Inventory.ChangeEvent
  alias Renga.Repo
  alias Renga.Scim.Client
  alias Renga.Scim.Connection
  alias Renga.Scim.DirectoryUser
  alias Renga.Scim.Filter
  alias Renga.Scim.Grants
  alias Renga.Scim.UserResource

  @filters %{
    "id" => :id,
    "userName" => :user_name,
    "externalId" => :external_id,
    "displayName" => :display_name
  }

  @doc "An entry of the connection by SCIM id, with its groups, or nil."
  def get(%Connection{id: connection_id}, id) do
    case Ecto.UUID.cast(id || "") do
      {:ok, id} ->
        DirectoryUser
        |> Repo.get_by(id: id, connection_id: connection_id)
        |> Repo.preload(groups: groups_query())

      :error ->
        nil
    end
  end

  @doc """
  One page of the connection's entries, oldest first, and how many match:
  `{:ok, {total, entries}}`. `filter` is nil or an `eq` filter on `id`,
  `userName`, `externalId`, or `displayName`; `start_index` counts from 1.
  """
  def list(%Connection{id: connection_id}, filter, start_index, count) do
    with {:ok, query} <- filtered(where(DirectoryUser, connection_id: ^connection_id), filter) do
      total = Repo.aggregate(query, :count)

      entries =
        query
        |> order_by([user], asc: user.inserted_at, asc: user.id)
        |> offset(^(start_index - 1))
        |> limit(^count)
        |> preload(groups: ^groups_query())
        |> Repo.all()

      {:ok, {total, entries}}
    end
  end

  @doc "Creates an entry from a SCIM User resource."
  def create(%Client{} = client, resource) do
    write(client, fn ->
      with {:ok, attrs} <- UserResource.create(resource),
           {:ok, user} <- insert_user(client.connection, attrs) do
        record!(client, "scim_user_created", user)
        {:ok, with_groups(user)}
      end
    end)
  end

  @doc "Replaces an entry's attributes from a SCIM User resource (PUT)."
  def replace(%Client{} = client, id, resource) do
    write(client, fn ->
      with {:ok, user} <- lock_user(client.connection, id),
           before = Grants.users_of_entries([user.id]),
           {:ok, attrs} <- UserResource.replace(resource, user),
           {:ok, updated} <- update_user(user, attrs) do
        record!(client, "scim_user_updated", updated)
        reconcile!(client, before ++ Grants.users_of_entries([user.id]))
        {:ok, with_groups(updated)}
      end
    end)
  end

  @doc "Applies SCIM PATCH operations to an entry."
  def patch(%Client{} = client, id, operations) do
    write(client, fn ->
      with {:ok, user} <- lock_user(client.connection, id),
           before = Grants.users_of_entries([user.id]),
           {:ok, attrs} <- UserResource.patch(operations, user),
           {:ok, updated} <- update_user(user, attrs) do
        record!(client, "scim_user_updated", updated)
        reconcile!(client, before ++ Grants.users_of_entries([user.id]))
        {:ok, with_groups(updated)}
      end
    end)
  end

  @doc "Deletes an entry. Activity history attributed to its account stays."
  def delete(%Client{} = client, id) do
    write(client, fn ->
      with {:ok, user} <- lock_user(client.connection, id),
           before = Grants.users_of_entries([user.id]),
           {:ok, deleted} <- Repo.delete(user) do
        record!(client, "scim_user_deleted", deleted)
        reconcile!(client, before)
        {:ok, deleted}
      end
    end)
  end

  defp reconcile!(%Client{connection: connection} = client, user_ids),
    do: Grants.reconcile!(connection.organization_id, user_ids, Client.cause(client))

  defp with_groups(user), do: Repo.preload(user, [groups: groups_query()], force: true)

  defp groups_query, do: order_by(Renga.Scim.DirectoryGroup, [group], asc: group.display_name)

  defp write(%Client{connection: connection}, mutation) do
    Grants.announcing(fn -> transact(connection, mutation) end)
  end

  defp transact(connection, mutation) do
    Repo.transaction(fn ->
      Authorization.lock_active_organization!(connection.organization_id)

      case mutation.() do
        {:ok, result} -> result
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  defp lock_user(%Connection{id: connection_id}, id) do
    with {:ok, id} <- Ecto.UUID.cast(id || ""),
         %DirectoryUser{} = user <-
           DirectoryUser
           |> where([user], user.connection_id == ^connection_id and user.id == ^id)
           |> lock("FOR UPDATE")
           |> Repo.one() do
      {:ok, user}
    else
      _missing -> {:error, :not_found}
    end
  end

  defp insert_user(connection, attrs) do
    %DirectoryUser{organization_id: connection.organization_id, connection_id: connection.id}
    |> DirectoryUser.changeset(attrs)
    |> Repo.insert()
    |> changeset_result()
  end

  defp update_user(user, attrs) do
    user
    |> DirectoryUser.changeset(attrs)
    |> Repo.update()
    |> changeset_result()
  end

  defp changeset_result({:ok, user}), do: {:ok, user}

  defp changeset_result({:error, changeset}) do
    {field, {message, opts}} = hd(changeset.errors)
    name = field |> Atom.to_string() |> Macro.camelize() |> uncapitalize()

    detail = "#{name} #{interpolate(message, opts)}"

    if opts[:constraint] == :unique,
      do: {:error, {:uniqueness, detail}},
      else: {:error, {:invalid_value, detail}}
  end

  # Ecto keeps messages as templates such as "should be at most %{count}
  # character(s)"; a SCIM detail is read as is.
  defp interpolate(message, opts) do
    Regex.replace(~r/%{(\w+)}/, message, fn match, key ->
      opts |> Keyword.get(String.to_existing_atom(key), match) |> to_string()
    end)
  end

  defp uncapitalize(<<first::utf8, rest::binary>>), do: String.downcase(<<first::utf8>>) <> rest

  defp filtered(query, nil), do: {:ok, query}

  defp filtered(query, filter) do
    case Filter.parse(filter, @filters) do
      {:ok, {:id, value}} ->
        case Ecto.UUID.cast(value) do
          {:ok, id} -> {:ok, where(query, [user], user.id == ^id)}
          :error -> {:ok, where(query, false)}
        end

      # displayName is not case-exact (RFC 7643); userName is citext.
      {:ok, {:display_name, value}} ->
        {:ok,
         where(query, [user], fragment("lower(?)", user.display_name) == ^String.downcase(value))}

      {:ok, {field, value}} ->
        {:ok, where(query, [user], field(user, ^field) == ^value)}

      {:error, detail} ->
        {:error, {:invalid_filter, detail}}
    end
  end

  defp record!(%Client{connection: connection} = client, kind, user) do
    %ChangeEvent{organization_id: connection.organization_id}
    |> ChangeEvent.changeset(%{
      kind: kind,
      metadata: %{
        "connection_id" => connection.id,
        "token_id" => client.token_id,
        "request_id" => client.request_id,
        "scim_user_id" => user.id,
        "user_name" => user.user_name
      },
      occurred_at: Renga.Time.utc_now_ms()
    })
    |> Repo.insert!()
  end
end
