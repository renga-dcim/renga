defmodule Renga.Repo.Migrations.AllowOwnerChangeRequests do
  @moduledoc "Members may request an owning team for a resource, as they request lifecycle changes."

  use Ecto.Migration

  def up do
    drop constraint(:change_requests, :change_requests_valid_kind)

    create constraint(:change_requests, :change_requests_valid_kind,
             check: "kind IN ('lifecycle', 'field_override', 'owner')"
           )
  end

  def down do
    execute "DELETE FROM change_requests WHERE kind = 'owner'"
    drop constraint(:change_requests, :change_requests_valid_kind)

    create constraint(:change_requests, :change_requests_valid_kind,
             check: "kind IN ('lifecycle', 'field_override')"
           )
  end
end
