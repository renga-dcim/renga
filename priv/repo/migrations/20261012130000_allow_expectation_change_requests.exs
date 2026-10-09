defmodule Renga.Repo.Migrations.AllowExpectationChangeRequests do
  @moduledoc """
  Members may request that a resource expect different hardware (RFD 8,
  "Editing hardware components"); only owners and admins change it directly.
  """

  use Ecto.Migration

  def up do
    drop constraint(:change_requests, :change_requests_valid_kind)

    create constraint(:change_requests, :change_requests_valid_kind,
             check: "kind IN ('lifecycle', 'field_override', 'owner', 'expectation')"
           )
  end

  def down do
    execute "DELETE FROM change_requests WHERE kind = 'expectation'"
    drop constraint(:change_requests, :change_requests_valid_kind)

    create constraint(:change_requests, :change_requests_valid_kind,
             check: "kind IN ('lifecycle', 'field_override', 'owner')"
           )
  end
end
