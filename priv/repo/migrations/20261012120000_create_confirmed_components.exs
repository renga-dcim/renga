defmodule Renga.Repo.Migrations.CreateConfirmedComponents do
  @moduledoc """
  Replacement parts people confirm on a resource (RFD 8, "Editing hardware
  components"): "a replacement was installed".

  A confirmation belongs to one expectation of one hardware assignment, the
  template it materializes or the local exception that added it, and goes
  with the assignment or exception. It records the installed part so the
  slot expects that part; the finding it explains closes only when a
  collector reports the part.
  """

  use Ecto.Migration

  def change do
    create table(:confirmed_components, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :organization_id, references(:organizations, on_delete: :delete_all, type: :binary_id),
        null: false

      add :hardware_assignment_id,
          references(:hardware_assignments,
            with: [organization_id: :organization_id],
            on_delete: :delete_all,
            type: :binary_id,
            name: :confirmed_components_tenant_assignment_fkey
          ),
          null: false

      add :component_template_id,
          references(:component_templates,
            with: [organization_id: :organization_id],
            on_delete: :restrict,
            type: :binary_id,
            name: :confirmed_components_tenant_template_fkey
          )

      add :exception_id,
          references(:expected_component_exceptions,
            with: [organization_id: :organization_id],
            on_delete: :delete_all,
            type: :binary_id,
            name: :confirmed_components_tenant_exception_fkey
          )

      add :part_number, :string
      add :serial_number, :string
      add :model, :string
      add :note, :text
      add :confirmed_by_user_id, references(:users, on_delete: :nilify_all, type: :binary_id)
      add :confirmed_at, :utc_datetime_usec, null: false

      timestamps(type: :"timestamp(3)")
    end

    # A confirmation explains exactly one expectation: a catalog template or,
    # for parts added on this resource only, the exception that added them.
    create constraint(:confirmed_components, :confirmed_components_one_expectation,
             check: "num_nonnulls(component_template_id, exception_id) = 1"
           )

    create constraint(:confirmed_components, :confirmed_components_identifies_part,
             check: "num_nonnulls(part_number, serial_number, model) > 0"
           )

    create unique_index(:confirmed_components, [:hardware_assignment_id, :component_template_id],
             where: "component_template_id IS NOT NULL",
             name: :confirmed_components_template_index
           )

    create unique_index(:confirmed_components, [:hardware_assignment_id, :exception_id],
             where: "exception_id IS NOT NULL",
             name: :confirmed_components_exception_index
           )
  end
end
