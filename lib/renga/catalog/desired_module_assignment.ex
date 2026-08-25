defmodule Renga.Catalog.DesiredModuleAssignment do
  use Ecto.Schema

  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec, autogenerate: {Renga.Time, :utc_now_ms, []}]

  schema "desired_module_assignments" do
    field :confirmed_by_user_id, :binary_id
    field :metadata, :map, default: %{}
    belongs_to :organization, Renga.Accounts.Organization
    belongs_to :module_bay, Renga.Catalog.ModuleBay
    belongs_to :module_type, Renga.Catalog.ModuleType
    timestamps()
  end

  def changeset(assignment, attrs) do
    assignment
    |> cast(attrs, [:module_type_id, :metadata])
    |> validate_required([
      :organization_id,
      :module_bay_id,
      :module_type_id,
      :confirmed_by_user_id
    ])
    |> validate_map(:metadata)
    |> assoc_constraint(:module_type, name: :desired_module_assignments_compatibility_fkey)
    |> unique_constraint([:organization_id, :module_bay_id],
      name: :desired_module_assignments_bay_index
    )
  end

  defp validate_map(changeset, field) do
    validate_change(changeset, field, fn ^field, value ->
      if is_map(value), do: [], else: [{field, "must be a map"}]
    end)
  end
end
