defmodule RengaWeb.Scim.DiscoveryController do
  @moduledoc """
  SCIM's discovery endpoints (RFC 7644, section 4): what Renga supports,
  which resource types it serves, and their schemas. `/Me` is not
  supported, and any other path under `/scim/v2` is not found.
  """

  use RengaWeb, :controller

  alias RengaWeb.Scim.Response
  alias RengaWeb.Scim.Schemas

  def service_provider_config(conn, _params),
    do: Response.json(conn, 200, Schemas.service_provider_config())

  def resource_types(conn, _params), do: list(conn, Schemas.resource_types())

  def resource_type(conn, %{"id" => id}), do: one(conn, Schemas.resource_type(id))

  def schemas(conn, _params), do: list(conn, Schemas.schemas())

  def schema(conn, %{"id" => id}), do: one(conn, Schemas.schema(id))

  def me(conn, _params),
    do: Response.error(conn, 501, "/Me is not supported; use /Users with the user's id")

  def not_found(conn, _params), do: Response.error(conn, 404, "No such SCIM resource")

  defp list(conn, resources) do
    Response.json(conn, 200, %{
      "schemas" => [Schemas.list_response_schema()],
      "totalResults" => length(resources),
      "startIndex" => 1,
      "itemsPerPage" => length(resources),
      "Resources" => resources
    })
  end

  defp one(conn, nil), do: not_found(conn, %{})
  defp one(conn, resource), do: Response.json(conn, 200, resource)
end
