defmodule Renga.Repo.Migrations.CreateModuleInstallations do
  use Ecto.Migration

  def up do
    create unique_index(
             :module_bay_compatible_types,
             [:module_bay_id, :organization_id, :module_type_id],
             name: :module_bay_compatible_types_assignment_index
           )

    create unique_index(:modules, [:id, :organization_id, :module_type_id],
             name: :modules_installation_index
           )

    create table(:desired_module_assignments, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :organization_id, :binary_id, null: false
      add :module_bay_id, :binary_id, null: false
      add :module_type_id, :binary_id, null: false

      add :confirmed_by_user_id, references(:users, on_delete: :restrict, type: :binary_id),
        null: false

      add :metadata, :map, null: false, default: %{}
      timestamps(type: :"timestamp(3)")
    end

    execute """
    ALTER TABLE desired_module_assignments
    ADD CONSTRAINT desired_module_assignments_compatibility_fkey
    FOREIGN KEY (module_bay_id, organization_id, module_type_id)
    REFERENCES module_bay_compatible_types(module_bay_id, organization_id, module_type_id)
    DEFERRABLE INITIALLY DEFERRED
    """

    execute """
    ALTER TABLE desired_module_assignments
    ADD CONSTRAINT desired_module_assignments_bay_fkey
    FOREIGN KEY (module_bay_id, organization_id)
    REFERENCES module_bays(id, organization_id)
    ON DELETE CASCADE
    """

    create unique_index(:desired_module_assignments, [:organization_id, :module_bay_id],
             name: :desired_module_assignments_bay_index
           )

    create table(:current_module_installations, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :organization_id, :binary_id, null: false
      add :module_bay_id, :binary_id, null: false
      add :module_id, :binary_id, null: false
      add :module_type_id, :binary_id, null: false
      add :installed_at, :"timestamp(3)", null: false
      add :metadata, :map, null: false, default: %{}
      timestamps(type: :"timestamp(3)")
    end

    execute """
    ALTER TABLE current_module_installations
    ADD CONSTRAINT current_module_installations_compatibility_fkey
    FOREIGN KEY (module_bay_id, organization_id, module_type_id)
    REFERENCES module_bay_compatible_types(module_bay_id, organization_id, module_type_id)
    DEFERRABLE INITIALLY DEFERRED
    """

    execute """
    ALTER TABLE current_module_installations
    ADD CONSTRAINT current_module_installations_bay_fkey
    FOREIGN KEY (module_bay_id, organization_id)
    REFERENCES module_bays(id, organization_id)
    ON DELETE CASCADE
    """

    execute """
    ALTER TABLE current_module_installations
    ADD CONSTRAINT current_module_installations_module_fkey
    FOREIGN KEY (module_id, organization_id, module_type_id)
    REFERENCES modules(id, organization_id, module_type_id)
    DEFERRABLE INITIALLY DEFERRED
    """

    create unique_index(:current_module_installations, [:organization_id, :module_bay_id],
             name: :current_module_installations_bay_index
           )

    create unique_index(:current_module_installations, [:organization_id, :module_id],
             name: :current_module_installations_module_index
           )

    create table(:module_installation_events, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :sequence, :bigserial, null: false
      add :organization_id, :binary_id, null: false

      add :module_bay_id,
          references(:module_bays,
            with: [organization_id: :organization_id],
            on_delete: :delete_all,
            type: :binary_id,
            name: :module_installation_events_bay_fkey
          ),
          null: false

      add :module_id,
          references(:modules,
            with: [organization_id: :organization_id],
            on_delete: :delete_all,
            type: :binary_id,
            name: :module_installation_events_module_fkey
          ),
          null: false

      add :action, :string, null: false
      add :occurred_at, :"timestamp(3)", null: false
      add :actor_user_id, references(:users, on_delete: :nilify_all, type: :binary_id)
      add :metadata, :map, null: false, default: %{}
      timestamps(type: :"timestamp(3)", updated_at: false)
    end

    create index(:module_installation_events, [:organization_id, :module_bay_id, :occurred_at],
             name: :module_installation_events_bay_time_index
           )
  end

  def down do
    drop table(:module_installation_events)
    drop table(:current_module_installations)
    drop table(:desired_module_assignments)

    drop index(:modules, [:id, :organization_id, :module_type_id],
           name: :modules_installation_index
         )

    drop index(:module_bay_compatible_types, [:module_bay_id, :organization_id, :module_type_id],
           name: :module_bay_compatible_types_assignment_index
         )
  end
end
