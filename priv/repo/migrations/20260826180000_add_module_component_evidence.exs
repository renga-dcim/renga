defmodule Renga.Repo.Migrations.AddModuleComponentEvidence do
  use Ecto.Migration

  def up do
    drop constraint(:component_evidence, :component_evidence_valid_kind)

    create constraint(:component_evidence, :component_evidence_valid_kind,
             check: "kind IN ('cpu', 'memory', 'disk', 'module')"
           )
  end

  def down do
    drop constraint(:component_evidence, :component_evidence_valid_kind)

    create constraint(:component_evidence, :component_evidence_valid_kind,
             check: "kind IN ('cpu', 'memory', 'disk')"
           )
  end
end
