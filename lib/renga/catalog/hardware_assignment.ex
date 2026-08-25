defmodule Renga.Catalog.HardwareAssignment do
  @moduledoc """
  Pins a physical resource to the catalog revision that defines its expectations.

  Reconciliation may replace reconciled assignments, but operator assignments
  are authoritative until an operator changes them.
  """

  use Ecto.Schema

  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec, autogenerate: {Renga.Time, :utc_now_ms, []}]

  schema "hardware_assignments" do
    field :origin, :string
    field :provenance, :map, default: %{}
    belongs_to :organization, Renga.Accounts.Organization
    belongs_to :resource, Renga.Inventory.Resource
    belongs_to :hardware_type, Renga.Catalog.HardwareType
    belongs_to :catalog_type_revision, Renga.Catalog.TypeRevision
    timestamps()
  end

  def changeset(assignment, attrs) do
    assignment
    |> cast(attrs, [:hardware_type_id, :catalog_type_revision_id, :origin, :provenance])
    |> validate_required([
      :organization_id,
      :resource_id,
      :hardware_type_id,
      :catalog_type_revision_id,
      :origin
    ])
    |> validate_inclusion(:origin, ~w(operator reconciled))
    |> validate_map(:provenance)
    |> assoc_constraint(:resource, name: :hardware_assignments_resource_fkey)
    |> assoc_constraint(:hardware_type, name: :hardware_assignments_hardware_type_fkey)
    |> assoc_constraint(:catalog_type_revision, name: :hardware_assignments_revision_fkey)
    |> unique_constraint([:organization_id, :resource_id])
  end

  defp validate_map(changeset, field) do
    validate_change(changeset, field, fn ^field, value ->
      if is_map(value), do: [], else: [{field, "must be a map"}]
    end)
  end
end
