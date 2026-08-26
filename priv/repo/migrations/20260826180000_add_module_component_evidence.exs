defmodule Renga.Repo.Migrations.AddModuleComponentEvidence do
  use Ecto.Migration

  def up do
    drop constraint(:component_evidence, :component_evidence_valid_kind)

    create constraint(:component_evidence, :component_evidence_valid_kind,
             check: "kind IN ('cpu', 'memory', 'disk', 'module')"
           )

    create constraint(:component_evidence, :component_evidence_module_position,
             check: """
             kind <> 'module' OR NULLIF(btrim(slot), '') IS NOT NULL OR
               NULLIF(btrim(path), '') IS NOT NULL
             """
           )
  end

  def down do
    drop constraint(:component_evidence, :component_evidence_module_position)

    # Module evidence is a derived projection; immutable observations retain the raw report.
    execute("DELETE FROM component_evidence WHERE kind = 'module'")

    drop constraint(:component_evidence, :component_evidence_valid_kind)

    create constraint(:component_evidence, :component_evidence_valid_kind,
             check: "kind IN ('cpu', 'memory', 'disk')"
           )
  end
end
