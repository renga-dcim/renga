defmodule Renga.Repo.Migrations.CreateExpectedComponents do
  use Ecto.Migration

  def up do
    create unique_index(:hardware_assignments, [:id, :organization_id])

    create unique_index(
             :hardware_assignments,
             [:id, :organization_id, :catalog_type_revision_id],
             name: :hardware_assignments_expectation_index
           )

    create unique_index(:component_templates, [:id, :organization_id])

    create unique_index(:component_templates, [:id, :organization_id, :catalog_type_revision_id],
             name: :component_templates_expectation_index
           )

    create table(:expected_component_exceptions, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :organization_id, :binary_id, null: false

      add :hardware_assignment_id,
          references(:hardware_assignments,
            with: [organization_id: :organization_id],
            on_delete: :delete_all,
            type: :binary_id,
            name: :expected_component_exceptions_assignment_fkey
          ),
          null: false

      add :component_template_id,
          references(:component_templates,
            with: [organization_id: :organization_id],
            on_delete: :restrict,
            type: :binary_id,
            name: :expected_component_exceptions_template_fkey
          )

      add :action, :string, null: false
      add :kind, :string
      add :name, :string
      add :changes, :map, null: false, default: %{}

      add :confirmed_by_user_id,
          references(:users, on_delete: :restrict, type: :binary_id),
          null: false

      timestamps(type: :"timestamp(3)")
    end

    create constraint(:expected_component_exceptions, :expected_component_exceptions_valid_shape,
             check: """
             (action = 'add' AND component_template_id IS NULL AND kind IS NOT NULL AND name IS NOT NULL)
             OR (action IN ('suppress', 'alter') AND component_template_id IS NOT NULL)
             """
           )

    create unique_index(
             :expected_component_exceptions,
             [:organization_id, :hardware_assignment_id, :component_template_id],
             where: "component_template_id IS NOT NULL",
             name: :expected_component_exceptions_template_index
           )

    create unique_index(:expected_component_exceptions, [:id, :organization_id])

    create table(:expected_components, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :organization_id, :binary_id, null: false

      add :hardware_assignment_id,
          references(:hardware_assignments,
            with: [organization_id: :organization_id],
            on_delete: :delete_all,
            type: :binary_id,
            name: :expected_components_assignment_fkey
          ),
          null: false

      add :catalog_type_revision_id, :binary_id, null: false
      add :component_template_id, :binary_id

      add :exception_id,
          references(:expected_component_exceptions,
            with: [organization_id: :organization_id],
            on_delete: :restrict,
            type: :binary_id,
            name: :expected_components_exception_fkey
          )

      add :kind, :string, null: false
      add :name, :string, null: false
      add :label, :string
      add :position, :string
      add :description, :text
      add :required, :boolean, null: false
      add :suppressed, :boolean, null: false, default: false
      add :attributes, :map, null: false, default: %{}
      timestamps(type: :"timestamp(3)")
    end

    execute """
    ALTER TABLE expected_components
    ADD CONSTRAINT expected_components_assignment_revision_fkey
    FOREIGN KEY (hardware_assignment_id, organization_id, catalog_type_revision_id)
    REFERENCES hardware_assignments(id, organization_id, catalog_type_revision_id)
    ON DELETE CASCADE
    """

    execute """
    ALTER TABLE expected_components
    ADD CONSTRAINT expected_components_template_fkey
    FOREIGN KEY (component_template_id, organization_id, catalog_type_revision_id)
    REFERENCES component_templates(id, organization_id, catalog_type_revision_id)
    ON DELETE RESTRICT
    """

    create unique_index(
             :expected_components,
             [:organization_id, :hardware_assignment_id, :kind, :name],
             name: :expected_components_assignment_kind_name_index
           )

    create index(:expected_components, [:organization_id, :hardware_assignment_id, :suppressed],
             name: :expected_components_assignment_suppressed_index
           )
  end

  def down do
    drop table(:expected_components)
    drop table(:expected_component_exceptions)

    drop index(:component_templates, [:id, :organization_id, :catalog_type_revision_id],
           name: :component_templates_expectation_index
         )

    drop index(:component_templates, [:id, :organization_id])

    drop_if_exists index(
                     :hardware_assignments,
                     [:id, :organization_id, :catalog_type_revision_id],
                     name: :hardware_assignments_expectation_index
                   )

    drop index(:hardware_assignments, [:id, :organization_id])
  end
end
