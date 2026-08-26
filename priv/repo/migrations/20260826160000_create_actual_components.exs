defmodule Renga.Repo.Migrations.CreateActualComponents do
  use Ecto.Migration

  def up do
    create table(:actual_components, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :organization_id, :binary_id, null: false

      add :owner_resource_id,
          references(:resources,
            with: [organization_id: :organization_id],
            on_delete: :delete_all,
            type: :binary_id,
            name: :actual_components_owner_resource_fkey
          ),
          null: false

      add :kind, :string, null: false
      add :status, :string, null: false, default: "present"
      add :name, :string
      add :model, :string
      add :slot, :string
      add :path, :string
      add :serial_number, :string
      add :part_number, :string
      add :attributes, :map, null: false, default: %{}
      add :metadata, :map, null: false, default: %{}
      add :first_observed_at, :"timestamp(3)", null: false
      add :last_observed_at, :"timestamp(3)", null: false
      timestamps(type: :"timestamp(3)")
    end

    create unique_index(:actual_components, [:id, :organization_id, :owner_resource_id],
             name: :actual_components_evidence_owner_index
           )

    create unique_index(
             :actual_components,
             [:organization_id, :owner_resource_id, :kind, "lower(serial_number)"],
             where: "serial_number IS NOT NULL",
             name: :actual_components_serial_identity_index
           )

    create index(:actual_components, [:organization_id, :owner_resource_id, :kind, :slot],
             name: :actual_components_owner_kind_slot_index
           )

    create index(:actual_components, [:organization_id, :owner_resource_id, :kind, :path],
             name: :actual_components_owner_kind_path_index
           )

    create constraint(:actual_components, :actual_components_valid_kind,
             check: "kind IN ('cpu', 'memory', 'disk')"
           )

    create constraint(:actual_components, :actual_components_valid_status,
             check: "status IN ('present', 'missing', 'unknown')"
           )

    create constraint(:actual_components, :actual_components_observation_order,
             check: "first_observed_at <= last_observed_at"
           )

    create unique_index(:component_evidence, [:id, :organization_id, :resource_id],
             name: :component_evidence_actual_component_index
           )

    create table(:actual_component_evidence_matches, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :organization_id, :binary_id, null: false
      add :owner_resource_id, :binary_id, null: false

      add :actual_component_id,
          references(:actual_components,
            with: [organization_id: :organization_id, owner_resource_id: :owner_resource_id],
            on_delete: :delete_all,
            type: :binary_id,
            name: :actual_component_evidence_matches_component_fkey
          ),
          null: false

      add :component_evidence_id,
          references(:component_evidence,
            with: [organization_id: :organization_id, owner_resource_id: :resource_id],
            on_delete: :delete_all,
            type: :binary_id,
            name: :actual_component_evidence_matches_evidence_fkey
          ),
          null: false

      add :match_strategy, :string, null: false
      timestamps(type: :"timestamp(3)", updated_at: false)
    end

    create unique_index(:actual_component_evidence_matches, [:component_evidence_id],
             name: :actual_component_evidence_matches_evidence_index
           )

    create index(
             :actual_component_evidence_matches,
             [:organization_id, :owner_resource_id, :actual_component_id],
             name: :actual_component_evidence_matches_component_index
           )

    create constraint(
             :actual_component_evidence_matches,
             :actual_component_evidence_matches_valid_strategy,
             check:
               "match_strategy IN ('discovered', 'serial_number', 'provider_id', 'position_part_number')"
           )
  end

  def down do
    drop table(:actual_component_evidence_matches)

    drop index(:component_evidence, [:id, :organization_id, :resource_id],
           name: :component_evidence_actual_component_index
         )

    drop table(:actual_components)
  end
end
