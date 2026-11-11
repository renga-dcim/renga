defmodule Renga.UsageTelemetry do
  @moduledoc """
  Organization attribution for database queries, including raw SQL. The
  context belongs to the process doing the work, never to a pooled connection.
  Background tasks must carry it explicitly with `with_organization/2`.
  """
  @key {__MODULE__, :organization_id}

  def organization_id, do: Process.get(@key)
  def put_organization(organization_id), do: Process.put(@key, organization_id)

  # Ecto runs handlers synchronously in the querying process. This covers
  # raw SQL as well as ORM calls, without tagging pooled connections or SQL.
  def database_query(_event, measurements, _metadata, _config) do
    if organization_id = organization_id() do
      :telemetry.execute([:renga, :organization, :database], measurements, %{
        organization_id: organization_id
      })
    end
  end

  def with_organization(organization_id, fun) do
    previous = put_organization(organization_id)

    try do
      fun.()
    after
      put_organization(previous)
    end
  end
end
