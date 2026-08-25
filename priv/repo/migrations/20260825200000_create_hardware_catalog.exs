defmodule Renga.Repo.Migrations.CreateHardwareCatalog do
  use Ecto.Migration

  def up do
    execute """
    CREATE FUNCTION enforce_resource_kind_immutability() RETURNS trigger AS $$
    BEGIN
      IF NEW.kind IS DISTINCT FROM OLD.kind THEN
        RAISE EXCEPTION 'resource kind is immutable'
          USING ERRCODE = '23514', CONSTRAINT = 'resources_kind_immutable';
      END IF;

      RETURN NEW;
    END;
    $$ LANGUAGE plpgsql
    """

    execute """
    CREATE TRIGGER resources_enforce_kind_immutability
    BEFORE UPDATE OF kind ON resources
    FOR EACH ROW EXECUTE FUNCTION enforce_resource_kind_immutability()
    """

    create_projection(:manufacturers, fn ->
      add :slug, :string, null: false
      add :description, :text
      add :metadata, :map, null: false, default: %{}
    end)

    create unique_index(:manufacturers, [:id, :organization_id])
    create unique_index(:manufacturers, [:organization_id, :slug])

    create_projection(:hardware_types, fn ->
      add :manufacturer_id,
          references(:manufacturers,
            with: [organization_id: :organization_id],
            on_delete: :restrict,
            type: :binary_id,
            name: :hardware_types_organization_manufacturer_fkey
          ),
          null: false

      add :model, :string, null: false
      add :device_class, :string, null: false
      add :description, :text
      add :metadata, :map, null: false, default: %{}
    end)

    create unique_index(:hardware_types, [:id, :organization_id])

    create unique_index(:hardware_types, [:organization_id, :manufacturer_id, "lower(model)"],
             name: :hardware_types_organization_manufacturer_model_index
           )

    create_projection(:module_types, fn ->
      add :manufacturer_id,
          references(:manufacturers,
            with: [organization_id: :organization_id],
            on_delete: :restrict,
            type: :binary_id,
            name: :module_types_organization_manufacturer_fkey
          ),
          null: false

      add :model, :string, null: false
      add :module_class, :string, null: false
      add :description, :text
      add :metadata, :map, null: false, default: %{}
    end)

    create unique_index(:module_types, [:id, :organization_id])

    create unique_index(:module_types, [:organization_id, :manufacturer_id, "lower(model)"],
             name: :module_types_organization_manufacturer_model_index
           )

    create table(:catalog_type_revisions, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :organization_id, :binary_id, null: false

      add :hardware_type_id,
          references(:hardware_types,
            with: [organization_id: :organization_id],
            on_delete: :delete_all,
            type: :binary_id,
            name: :catalog_type_revisions_hardware_type_fkey
          )

      add :module_type_id,
          references(:module_types,
            with: [organization_id: :organization_id],
            on_delete: :delete_all,
            type: :binary_id,
            name: :catalog_type_revisions_module_type_fkey
          )

      add :revision, :integer, null: false
      add :part_number, :string
      add :height_units, :integer
      add :width_mm, :decimal, precision: 10, scale: 2
      add :depth_mm, :decimal, precision: 10, scale: 2
      add :weight_kg, :decimal, precision: 10, scale: 3
      add :airflow, :string
      add :specifications, :map, null: false, default: %{}
      add :finalized_at, :"timestamp(3)"
      timestamps(type: :"timestamp(3)", updated_at: false)
    end

    create constraint(:catalog_type_revisions, :catalog_type_revisions_one_owner,
             check:
               "(hardware_type_id IS NOT NULL AND module_type_id IS NULL) OR " <>
                 "(hardware_type_id IS NULL AND module_type_id IS NOT NULL)"
           )

    create constraint(:catalog_type_revisions, :catalog_type_revisions_valid_dimensions,
             check:
               "revision > 0 AND (height_units IS NULL OR height_units > 0) AND " <>
                 "(width_mm IS NULL OR width_mm > 0) AND (depth_mm IS NULL OR depth_mm > 0) AND " <>
                 "(weight_kg IS NULL OR weight_kg > 0)"
           )

    create unique_index(:catalog_type_revisions, [:id, :organization_id])

    create unique_index(:catalog_type_revisions, [:organization_id, :hardware_type_id, :revision],
             where: "hardware_type_id IS NOT NULL",
             name: :catalog_type_revisions_hardware_revision_index
           )

    create unique_index(:catalog_type_revisions, [:organization_id, :module_type_id, :revision],
             where: "module_type_id IS NOT NULL",
             name: :catalog_type_revisions_module_revision_index
           )

    create table(:component_templates, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :organization_id, :binary_id, null: false

      add :catalog_type_revision_id,
          references(:catalog_type_revisions,
            with: [organization_id: :organization_id],
            on_delete: :delete_all,
            type: :binary_id,
            name: :component_templates_revision_fkey
          ),
          null: false

      add :kind, :string, null: false
      add :name, :string, null: false
      add :label, :string
      add :position, :string
      add :description, :text
      add :required, :boolean, null: false, default: true
      add :attributes, :map, null: false, default: %{}
      timestamps(type: :"timestamp(3)", updated_at: false)
    end

    create unique_index(:component_templates, [
             :organization_id,
             :catalog_type_revision_id,
             :kind,
             :name
           ])

    create index(:component_templates, [:organization_id, :kind])

    execute """
    CREATE FUNCTION enforce_catalog_type_revision_immutability() RETURNS trigger AS $$
    BEGIN
      IF TG_OP = 'DELETE' THEN
        IF NOT EXISTS (SELECT 1 FROM organizations WHERE id = OLD.organization_id) THEN
          RETURN OLD;
        END IF;
      ELSIF OLD.finalized_at IS NULL
            AND NEW.finalized_at IS NOT NULL
            AND (to_jsonb(NEW) - 'finalized_at') = (to_jsonb(OLD) - 'finalized_at') THEN
        RETURN NEW;
      END IF;

      RAISE EXCEPTION 'catalog revisions are immutable'
        USING ERRCODE = '23514', CONSTRAINT = 'catalog_type_revisions_immutable';
    END;
    $$ LANGUAGE plpgsql
    """

    execute """
    CREATE TRIGGER catalog_type_revisions_enforce_immutability
    BEFORE UPDATE OR DELETE ON catalog_type_revisions
    FOR EACH ROW EXECUTE FUNCTION enforce_catalog_type_revision_immutability()
    """

    execute """
    CREATE FUNCTION enforce_component_template_immutability() RETURNS trigger AS $$
    DECLARE
      old_finalized_at timestamp;
      new_finalized_at timestamp;
    BEGIN
      IF TG_OP = 'DELETE'
         AND NOT EXISTS (SELECT 1 FROM organizations WHERE id = OLD.organization_id) THEN
        RETURN OLD;
      END IF;

      IF TG_OP IN ('UPDATE', 'DELETE') THEN
        SELECT finalized_at INTO old_finalized_at
        FROM catalog_type_revisions
        WHERE id = OLD.catalog_type_revision_id
          AND organization_id = OLD.organization_id;
      END IF;

      IF TG_OP IN ('INSERT', 'UPDATE') THEN
        SELECT finalized_at INTO new_finalized_at
        FROM catalog_type_revisions
        WHERE id = NEW.catalog_type_revision_id
          AND organization_id = NEW.organization_id;
      END IF;

      IF old_finalized_at IS NOT NULL OR new_finalized_at IS NOT NULL THEN
        RAISE EXCEPTION 'component templates are immutable after revision finalization'
          USING ERRCODE = '23514', CONSTRAINT = 'component_templates_revision_finalized';
      END IF;

      RETURN CASE WHEN TG_OP = 'DELETE' THEN OLD ELSE NEW END;
    END;
    $$ LANGUAGE plpgsql
    """

    execute """
    CREATE TRIGGER component_templates_enforce_immutability
    BEFORE INSERT OR UPDATE OR DELETE ON component_templates
    FOR EACH ROW EXECUTE FUNCTION enforce_component_template_immutability()
    """
  end

  def down do
    execute "DROP TRIGGER component_templates_enforce_immutability ON component_templates"
    execute "DROP FUNCTION enforce_component_template_immutability()"
    execute "DROP TRIGGER catalog_type_revisions_enforce_immutability ON catalog_type_revisions"
    execute "DROP FUNCTION enforce_catalog_type_revision_immutability()"
    execute "DROP TRIGGER resources_enforce_kind_immutability ON resources"
    execute "DROP FUNCTION enforce_resource_kind_immutability()"

    execute "DELETE FROM resources WHERE kind IN ('hardware_type', 'module_type')"
    execute "DELETE FROM resources WHERE kind = 'manufacturer'"

    drop table(:component_templates)
    drop table(:catalog_type_revisions)
    drop table(:module_types)
    drop table(:hardware_types)
    drop table(:manufacturers)
  end

  defp create_projection(table_name, fields) do
    create table(table_name, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :organization_id, :binary_id, null: false

      add :resource_id,
          references(:resources,
            with: [organization_id: :organization_id],
            on_delete: :delete_all,
            type: :binary_id,
            name: :"#{table_name}_organization_resource_fkey"
          ),
          null: false

      fields.()
      timestamps(type: :"timestamp(3)")
    end

    create unique_index(table_name, [:organization_id, :resource_id])
  end
end
