defmodule Renga.Repo.Migrations.CreateHardwareAssignments do
  use Ecto.Migration

  def up do
    create unique_index(
             :catalog_type_revisions,
             [:id, :organization_id, :hardware_type_id],
             name: :catalog_type_revisions_hardware_assignment_index
           )

    create table(:hardware_assignments, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :organization_id, :binary_id, null: false

      add :resource_id,
          references(:resources,
            with: [organization_id: :organization_id],
            on_delete: :delete_all,
            type: :binary_id,
            name: :hardware_assignments_resource_fkey
          ),
          null: false

      add :hardware_type_id,
          references(:hardware_types,
            with: [organization_id: :organization_id],
            on_delete: :restrict,
            type: :binary_id,
            name: :hardware_assignments_hardware_type_fkey
          ),
          null: false

      add :catalog_type_revision_id, :binary_id, null: false
      add :origin, :string, null: false
      add :provenance, :map, null: false, default: %{}
      timestamps(type: :"timestamp(3)")
    end

    execute """
    ALTER TABLE hardware_assignments
    ADD CONSTRAINT hardware_assignments_revision_fkey
    FOREIGN KEY (catalog_type_revision_id, organization_id, hardware_type_id)
    REFERENCES catalog_type_revisions(id, organization_id, hardware_type_id)
    ON DELETE RESTRICT
    """

    create unique_index(:hardware_assignments, [:organization_id, :resource_id])
    create index(:hardware_assignments, [:organization_id, :hardware_type_id])

    create constraint(:hardware_assignments, :hardware_assignments_valid_origin,
             check: "origin IN ('operator', 'reconciled')"
           )

    create table(:hardware_match_findings, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :organization_id, :binary_id, null: false

      add :resource_id,
          references(:resources,
            with: [organization_id: :organization_id],
            on_delete: :delete_all,
            type: :binary_id,
            name: :hardware_match_findings_resource_fkey
          ),
          null: false

      add :kind, :string, null: false
      add :status, :string, null: false, default: "open"
      add :message, :text, null: false
      add :details, :map, null: false, default: %{}
      add :resolved_at, :"timestamp(3)"
      timestamps(type: :"timestamp(3)")
    end

    create unique_index(:hardware_match_findings, [:organization_id, :resource_id, :kind],
             where: "status = 'open'",
             name: :hardware_match_findings_open_kind_index
           )

    create index(:hardware_match_findings, [:organization_id, :status, :kind])
  end

  def down do
    drop table(:hardware_match_findings)
    drop table(:hardware_assignments)

    drop_if_exists index(
                     :catalog_type_revisions,
                     [:id, :organization_id, :hardware_type_id],
                     name: :catalog_type_revisions_hardware_assignment_index
                   )
  end
end
