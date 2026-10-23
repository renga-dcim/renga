defmodule RengaWeb.Scim.GroupJSON do
  @moduledoc "Renders directory groups as SCIM Group resources (RFC 7643, section 4.2)."

  use RengaWeb, :verified_routes

  alias Renga.Scim.DirectoryGroup
  alias RengaWeb.Scim.Schemas
  alias RengaWeb.Scim.UserJSON

  def location(%DirectoryGroup{id: id}), do: url(~p"/scim/v2/Groups/#{id}")

  @doc "The group; `members` is left out when they were not loaded."
  def render(%DirectoryGroup{} = group) do
    %{
      "schemas" => [Schemas.group_schema()],
      "id" => group.id,
      "externalId" => group.external_id,
      "displayName" => group.display_name,
      "members" => members(group.members),
      "meta" => %{
        "resourceType" => "Group",
        "created" => DateTime.to_iso8601(group.inserted_at),
        "lastModified" => DateTime.to_iso8601(group.updated_at),
        "location" => location(group)
      }
    }
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  defp members(%Ecto.Association.NotLoaded{}), do: nil

  defp members(members) do
    Enum.map(members, fn user ->
      %{
        "value" => user.id,
        "$ref" => UserJSON.location(user),
        "display" => user.display_name || user.user_name
      }
    end)
  end
end
