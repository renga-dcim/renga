defmodule Renga.Repo.Migrations.CreateModulesAndBays do
  use Ecto.Migration

  def up do
    create unique_index(
             :catalog_type_revisions,
             [:id, :organization_id, :module_type_id],
             name: :catalog_type_revisions_module_assignment_index
           )

    create table(:modules, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :organization_id, :binary_id, null: false

      add :resource_id,
          references(:resources,
            with: [organization_id: :organization_id],
            on_delete: :delete_all,
            type: :binary_id,
            name: :modules_resource_fkey
          ),
          null: false

      add :module_type_id,
          references(:module_types,
            with: [organization_id: :organization_id],
            on_delete: :restrict,
            type: :binary_id,
            name: :modules_module_type_fkey
          ),
          null: false

      add :catalog_type_revision_id, :binary_id, null: false
      add :status, :string, null: false, default: "unknown"
      add :serial_number, :string
      add :part_number, :string
      add :asset_tag, :string
      add :metadata, :map, null: false, default: %{}
      timestamps(type: :"timestamp(3)")
    end

    execute """
    ALTER TABLE modules
    ADD CONSTRAINT modules_revision_fkey
    FOREIGN KEY (catalog_type_revision_id, organization_id, module_type_id)
    REFERENCES catalog_type_revisions(id, organization_id, module_type_id)
    ON DELETE RESTRICT
    """

    create unique_index(:modules, [:id, :organization_id])
    create unique_index(:modules, [:organization_id, :resource_id])
    create index(:modules, [:organization_id, :module_type_id])

    create unique_index(:resources, [:id, :organization_id, :kind],
             name: :resources_module_owner_index
           )

    create table(:module_bays, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :organization_id, :binary_id, null: false
      add :owner_resource_id, :binary_id, null: false
      add :owner_kind, :string, null: false
      add :name, :string, null: false
      add :label, :string
      add :position, :string
      add :status, :string, null: false, default: "active"
      add :metadata, :map, null: false, default: %{}
      timestamps(type: :"timestamp(3)")
    end

    execute """
    ALTER TABLE module_bays
    ADD CONSTRAINT module_bays_owner_resource_fkey
    FOREIGN KEY (owner_resource_id, organization_id, owner_kind)
    REFERENCES resources(id, organization_id, kind)
    ON DELETE CASCADE
    """

    create constraint(:module_bays, :module_bays_valid_owner_kind,
             check: "owner_kind IN ('server', 'switch', 'pdu', 'storage', 'module')"
           )

    create unique_index(:module_bays, [:id, :organization_id])

    create unique_index(:module_bays, [:organization_id, :owner_resource_id, "lower(name)"],
             name: :module_bays_owner_name_index
           )

    create table(:module_bay_compatible_types, primary_key: false) do
      add :organization_id, :binary_id, null: false

      add :module_bay_id,
          references(:module_bays,
            with: [organization_id: :organization_id],
            on_delete: :delete_all,
            type: :binary_id,
            name: :module_bay_compatible_types_bay_fkey
          ),
          primary_key: true

      add :module_type_id,
          references(:module_types,
            with: [organization_id: :organization_id],
            on_delete: :delete_all,
            type: :binary_id,
            name: :module_bay_compatible_types_type_fkey
          ),
          primary_key: true

      timestamps(type: :"timestamp(3)", updated_at: false)
    end

    create index(:module_bay_compatible_types, [:organization_id, :module_type_id],
             name: :module_bay_compatible_types_type_index
           )
  end

  def down do
    drop table(:module_bay_compatible_types)
    drop table(:module_bays)
    drop index(:resources, [:id, :organization_id, :kind], name: :resources_module_owner_index)
    drop table(:modules)

    drop index(:catalog_type_revisions, [:id, :organization_id, :module_type_id],
           name: :catalog_type_revisions_module_assignment_index
         )
  end
end
