defmodule Renga.Catalog.ExpectedComponent do
  @moduledoc """
  Materialized component expectation for one pinned asset assignment.

  These rows are desired structure only. Collector observations and canonical
  component evidence remain separate and cannot manufacture expectations.
  """

  use Ecto.Schema

  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec, autogenerate: {Renga.Time, :utc_now_ms, []}]
  @kinds ~w(interface module_bay power_port power_outlet console_port device_bay)

  schema "expected_components" do
    field :kind, :string
    field :name, :string
    field :label, :string
    field :position, :string
    field :description, :string
    field :required, :boolean, default: true
    field :suppressed, :boolean, default: false
    field :attributes, :map, default: %{}
    belongs_to :organization, Renga.Accounts.Organization
    belongs_to :hardware_assignment, Renga.Catalog.HardwareAssignment
    belongs_to :catalog_type_revision, Renga.Catalog.TypeRevision
    belongs_to :component_template, Renga.Catalog.ComponentTemplate
    belongs_to :exception, Renga.Catalog.ExpectedComponentException
    timestamps()
  end

  def changeset(component, attrs) do
    component
    |> cast(attrs, [
      :catalog_type_revision_id,
      :component_template_id,
      :exception_id,
      :kind,
      :name,
      :label,
      :position,
      :description,
      :required,
      :suppressed,
      :attributes
    ])
    |> validate_required([
      :organization_id,
      :hardware_assignment_id,
      :catalog_type_revision_id,
      :kind,
      :name,
      :required,
      :suppressed
    ])
    |> validate_inclusion(:kind, @kinds)
    |> assoc_constraint(:hardware_assignment,
      name: :expected_components_assignment_revision_fkey
    )
    |> assoc_constraint(:component_template, name: :expected_components_template_fkey)
    |> assoc_constraint(:exception, name: :expected_components_exception_fkey)
    |> unique_constraint([:organization_id, :hardware_assignment_id, :kind, :name],
      name: :expected_components_assignment_kind_name_index
    )
  end
end
