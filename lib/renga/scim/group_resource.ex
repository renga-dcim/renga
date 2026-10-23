defmodule Renga.Scim.GroupResource do
  @moduledoc """
  Turns SCIM Group requests into a group's attributes and member set,
  following RFD 16's write rules ("Directory entries"):

    * `members` omitted on POST makes an empty group; omitted on PUT
      empties it; supplied on either replaces the set whole.
    * PATCH add and remove change only the members they name; replace
      replaces the set. `members[value eq "..."]`, as Okta removes a
      member, names one.
    * `displayName` is required; `externalId` follows the same omitted,
      null, or empty rule as a user's.

  A result is `{:ok, attrs, members}` where `members` is the full set of
  member ids after the write. The caller validates that each one is an
  entry of the same connection.
  """

  alias Renga.Scim.Attributes
  alias Renga.Scim.Path

  @core "urn:ietf:params:scim:schemas:core:2.0:Group"
  @value_filter ~r/^\s*value\s+eq\s+("(?:[^"\\]|\\.)*")\s*$/i

  @doc "Attributes and members for a new group from a POST body."
  def create(resource) when is_map(resource), do: whole(resource)
  def create(_resource), do: invalid_syntax()

  @doc "Attributes and members replacing a group's from a PUT body."
  def replace(resource) when is_map(resource), do: whole(resource)
  def replace(_resource), do: invalid_syntax()

  @doc "Applies PATCH `operations` to `attrs` and `members`, in order."
  def patch(operations, attrs, members) when is_list(operations) do
    Enum.reduce_while(operations, {:ok, attrs, MapSet.new(members)}, fn operation,
                                                                        {:ok, attrs, members} ->
      case operation(operation, attrs, members) do
        {:ok, attrs, members} -> {:cont, {:ok, attrs, members}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, attrs, members} -> {:ok, attrs, MapSet.to_list(members)}
      error -> error
    end
  end

  def patch(_operations, _attrs, _members), do: invalid_syntax()

  defp whole(resource) do
    with {:ok, display_name} <- display_name(Attributes.get(resource, "displayName")),
         {:ok, external_id} <- string(Attributes.get(resource, "externalId"), "externalId"),
         {:ok, members} <- member_ids(Attributes.get(resource, "members", [])) do
      {:ok, %{display_name: display_name, external_id: external_id}, members}
    end
  end

  defp operation(%{} = operation, attrs, members) do
    with {:ok, op} <- Attributes.op(operation) do
      path = Attributes.get(operation, "path")
      targeted(op, path, Attributes.get(operation, "value"), attrs, members)
    end
  end

  defp operation(_operation, _attrs, _members),
    do: {:error, {:invalid_syntax, "Each operation must be an object"}}

  defp targeted("remove", path, _value, _attrs, _members) when path in [nil, ""],
    do: {:error, {:no_target, "A remove operation needs a path"}}

  defp targeted(op, path, value, attrs, members) when path in [nil, ""],
    do: pathless(op, value, attrs, members)

  defp targeted(_op, path, _value, _attrs, _members) when not is_binary(path),
    do: {:error, {:invalid_path, "The path must be a string"}}

  defp targeted(op, path, value, attrs, members) do
    case Path.parse(path, @core) do
      {:ok, parsed} -> apply_path(op, parsed, value, attrs, members)
      :extension -> {:ok, attrs, members}
      :error -> {:error, {:invalid_path, "#{path} is not a valid path"}}
    end
  end

  # Okta renames a group with {"op": "replace", "value": {"id": ..., "displayName": ...}}.
  defp pathless(op, value, attrs, members) when is_map(value) do
    Enum.reduce_while(value, {:ok, attrs, members}, fn {key, attribute_value},
                                                       {:ok, attrs, members} ->
      result =
        case Path.parse(key, @core) do
          {:ok, %{attribute: "id"}} -> {:ok, attrs, members}
          {:ok, parsed} -> apply_path(op, parsed, attribute_value, attrs, members)
          :extension -> {:ok, attrs, members}
          :error -> {:error, {:invalid_path, "#{key} is not a valid attribute"}}
        end

      case result do
        {:ok, attrs, members} -> {:cont, {:ok, attrs, members}}
        error -> {:halt, error}
      end
    end)
  end

  defp pathless(_op, _value, _attrs, _members),
    do: {:error, {:invalid_value, "An operation without a path needs an object value"}}

  defp apply_path("remove", %{attribute: "displayname", filter: nil}, _value, _attrs, _members),
    do: {:error, {:invalid_value, "displayName is required"}}

  defp apply_path(_op, %{attribute: "displayname", filter: nil, sub: nil}, value, attrs, members) do
    with {:ok, display_name} <- display_name(value),
         do: {:ok, %{attrs | display_name: display_name}, members}
  end

  defp apply_path("remove", %{attribute: "externalid", filter: nil}, _value, attrs, members),
    do: {:ok, %{attrs | external_id: nil}, members}

  defp apply_path(_op, %{attribute: "externalid", filter: nil, sub: nil}, value, attrs, members) do
    with {:ok, external_id} <- string(value, "externalId"),
         do: {:ok, %{attrs | external_id: external_id}, members}
  end

  # Without a value, remove empties the group.
  defp apply_path("remove", %{attribute: "members", filter: nil, sub: nil}, nil, attrs, _members),
    do: {:ok, attrs, MapSet.new()}

  defp apply_path(op, %{attribute: "members", filter: nil, sub: nil}, value, attrs, members) do
    with {:ok, ids} <- member_ids(List.wrap(value)),
         do: {:ok, attrs, change_members(op, members, MapSet.new(ids))}
  end

  defp apply_path(
         "remove",
         %{attribute: "members", filter: filter, sub: nil},
         _value,
         attrs,
         members
       )
       when is_binary(filter) do
    # The value is a JSON string literal (RFC 7644, section 3.4.2.2).
    with [_match, literal] <- Regex.run(@value_filter, filter),
         {:ok, id} when is_binary(id) <- Jason.decode(literal) do
      {:ok, attrs, MapSet.delete(members, canonical(id))}
    else
      _unreadable ->
        {:error, {:invalid_filter, ~s(Members can only be filtered by value eq "id")}}
    end
  end

  defp apply_path(_op, %{attribute: "members"}, _value, _attrs, _members),
    do: {:error, {:invalid_path, "Only whole members, or one member by value, can be changed"}}

  defp apply_path(_op, %{attribute: attribute}, _value, _attrs, _members)
       when attribute in ["id", "meta"],
       do: {:error, {:mutability, "#{attribute} is read-only"}}

  # Undeclared attributes are accepted and not kept.
  defp apply_path(_op, _path, _value, attrs, members), do: {:ok, attrs, members}

  defp change_members("add", members, ids), do: MapSet.union(members, ids)
  defp change_members("replace", _members, ids), do: ids
  defp change_members("remove", members, ids), do: MapSet.difference(members, ids)

  defp display_name(value) do
    case Attributes.optional_string(value) do
      {:ok, nil} -> {:error, {:invalid_value, "displayName is required"}}
      {:ok, display_name} -> {:ok, display_name}
      :error -> {:error, {:invalid_value, "displayName must be a string"}}
    end
  end

  defp string(value, name) do
    case Attributes.optional_string(value) do
      {:ok, string} -> {:ok, string}
      :error -> {:error, {:invalid_value, "#{name} must be a string"}}
    end
  end

  defp member_ids(nil), do: {:ok, []}

  defp member_ids(members) when is_list(members) do
    Enum.reduce_while(members, {:ok, []}, fn
      %{} = member, {:ok, ids} ->
        case Attributes.get(member, "value") do
          id when is_binary(id) and id != "" -> {:cont, {:ok, [canonical(id) | ids]}}
          _other -> {:halt, {:error, {:invalid_value, "Each member needs a value"}}}
        end

      _member, _acc ->
        {:halt, {:error, {:invalid_value, "members must be a list of objects"}}}
    end)
    |> case do
      {:ok, ids} -> {:ok, ids |> Enum.reverse() |> Enum.uniq()}
      error -> error
    end
  end

  defp member_ids(_members), do: {:error, {:invalid_value, "members must be a list"}}

  # Member ids are UUIDs, which providers may send in upper case; set
  # operations compare the stored lower-case form. Anything else is left for
  # the caller to refuse as not a member of the connection.
  defp canonical(id) do
    case Ecto.UUID.cast(id) do
      {:ok, uuid} -> uuid
      :error -> id
    end
  end

  defp invalid_syntax, do: {:error, {:invalid_syntax, "The request body must be a JSON object"}}
end
