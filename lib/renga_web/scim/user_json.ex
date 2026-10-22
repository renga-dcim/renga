defmodule RengaWeb.Scim.UserJSON do
  @moduledoc "Renders directory entries as SCIM User resources (RFC 7643, section 4.1)."

  use RengaWeb, :verified_routes

  alias Renga.Scim.DirectoryUser
  alias RengaWeb.Scim.Schemas

  def location(%DirectoryUser{id: id}), do: url(~p"/scim/v2/Users/#{id}")

  def render(%DirectoryUser{} = user) do
    name =
      %{
        "formatted" => user.formatted_name,
        "givenName" => user.given_name,
        "familyName" => user.family_name
      }
      |> compact()

    %{
      "schemas" => [Schemas.user_schema()],
      "id" => user.id,
      "externalId" => user.external_id,
      "userName" => user.user_name,
      "displayName" => user.display_name,
      "name" => if(name == %{}, do: nil, else: name),
      "emails" => if(user.email, do: [%{"value" => user.email, "primary" => true}]),
      "active" => user.active,
      "groups" => [],
      "meta" => %{
        "resourceType" => "User",
        "created" => DateTime.to_iso8601(user.inserted_at),
        "lastModified" => DateTime.to_iso8601(user.updated_at),
        "location" => location(user)
      }
    }
    |> compact()
  end

  defp compact(map), do: map |> Enum.reject(fn {_key, value} -> is_nil(value) end) |> Map.new()
end
