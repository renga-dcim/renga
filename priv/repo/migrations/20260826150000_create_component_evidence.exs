defmodule Renga.Repo.Migrations.CreateComponentEvidence do
  use Ecto.Migration

  def change do
    create table(:component_evidence, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :organization_id, references(:organizations, on_delete: :delete_all, type: :binary_id),
        null: false

      add :resource_id,
          references(:resources,
            with: [organization_id: :organization_id],
            on_delete: :delete_all,
            type: :binary_id,
            name: :component_evidence_tenant_resource_fkey
          ),
          null: false

      add :source_id,
          references(:sources,
            with: [organization_id: :organization_id],
            on_delete: :restrict,
            type: :binary_id,
            name: :component_evidence_tenant_source_fkey
          ),
          null: false

      add :observation_id,
          references(:observations,
            with: [organization_id: :organization_id, source_id: :source_id],
            on_delete: :restrict,
            type: :binary_id,
            name: :component_evidence_tenant_observation_fkey
          ),
          null: false

      add :kind, :string, null: false
      add :source_local_id, :string, null: false
      add :name, :string
      add :model, :string
      add :slot, :string
      add :path, :string
      add :serial_number, :string
      add :part_number, :string
      add :attributes, :map, null: false, default: %{}
      add :raw_metadata, :map, null: false, default: %{}
      add :observed_at, :"timestamp(3)", null: false
      timestamps(type: :"timestamp(3)")
    end

    create unique_index(
             :component_evidence,
             [:organization_id, :observation_id, :kind, :source_local_id],
             name: :component_evidence_observation_identity_index
           )

    create index(
             :component_evidence,
             [:organization_id, :resource_id, :source_id, :kind, :observed_at],
             name: :component_evidence_resource_source_kind_index
           )

    create constraint(:component_evidence, :component_evidence_valid_kind,
             check: "kind IN ('cpu', 'memory', 'disk')"
           )
  end
end
