defmodule Renga.Repo.Migrations.IndexComponentFindingMatches do
  use Ecto.Migration

  def change do
    create index(:actual_component_evidence_matches, [:organization_id, :owner_resource_id],
             include: [:component_evidence_id],
             name: :actual_component_evidence_matches_finding_scope_index
           )
  end
end
