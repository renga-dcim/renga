defmodule Renga.Repo.Migrations.IndexResourceClaimsForOperationalSummaries do
  use Ecto.Migration

  def change do
    create index(:resource_identifier_claims, [:organization_id, :resource_id])
  end
end
