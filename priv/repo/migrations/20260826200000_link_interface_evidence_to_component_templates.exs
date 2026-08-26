defmodule Renga.Repo.Migrations.LinkInterfaceEvidenceToComponentTemplates do
  use Ecto.Migration

  def change do
    alter table(:interface_evidence) do
      add :component_template_id,
          references(:component_templates,
            with: [organization_id: :organization_id],
            on_delete: :restrict,
            type: :binary_id,
            name: :interface_evidence_component_template_fkey
          )

      add :catalog_match_status, :string
      add :catalog_match_strategy, :string
    end

    create index(:interface_evidence, [:organization_id, :component_template_id],
             name: :interface_evidence_component_template_index
           )

    create constraint(:interface_evidence, :interface_evidence_catalog_match_shape,
             check: """
             (
               (catalog_match_status IS NULL AND component_template_id IS NULL AND catalog_match_strategy IS NULL)
               OR (catalog_match_status = 'matched' AND component_template_id IS NOT NULL AND catalog_match_strategy IN ('mac_address', 'name'))
               OR (catalog_match_status IN ('unmatched', 'ambiguous') AND component_template_id IS NULL AND catalog_match_strategy IS NULL)
             ) IS TRUE
             """
           )
  end
end
