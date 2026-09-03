defmodule Renga.Catalog.TypeRevision do
  use Ecto.Schema

  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [
    type: :utc_datetime_usec,
    autogenerate: {Renga.Time, :utc_now_ms, []},
    updated_at: false
  ]
  @airflows ~w(front_to_rear rear_to_front left_to_right right_to_left passive mixed)
  @max_integer 2_147_483_647
  @max_dimension Decimal.new("99999999.99")
  @max_weight Decimal.new("9999999.999")

  schema "catalog_type_revisions" do
    field :revision, :integer
    field :part_number, :string
    field :height_units, :integer
    field :width_mm, :decimal
    field :depth_mm, :decimal
    field :weight_kg, :decimal
    field :airflow, :string
    field :specifications, :map, default: %{}
    field :finalized_at, :utc_datetime_usec
    belongs_to :organization, Renga.Accounts.Organization
    belongs_to :hardware_type, Renga.Catalog.HardwareType
    belongs_to :module_type, Renga.Catalog.ModuleType

    has_many :component_templates, Renga.Catalog.ComponentTemplate,
      foreign_key: :catalog_type_revision_id

    timestamps()
  end

  def changeset(revision, attrs) do
    revision
    |> input_changeset(attrs)
    |> reject_mutation()
    |> validate_required([:organization_id, :revision])
    |> validate_number(:revision, greater_than: 0)
    |> check_constraint(:hardware_type_id, name: :catalog_type_revisions_one_owner)
    |> check_constraint(:revision, name: :catalog_type_revisions_valid_dimensions)
    |> assoc_constraint(:hardware_type, name: :catalog_type_revisions_hardware_type_fkey)
    |> assoc_constraint(:module_type, name: :catalog_type_revisions_module_type_fkey)
    |> unique_constraint([:organization_id, :hardware_type_id, :revision],
      name: :catalog_type_revisions_hardware_revision_index
    )
    |> unique_constraint([:organization_id, :module_type_id, :revision],
      name: :catalog_type_revisions_module_revision_index
    )
  end

  def input_changeset(revision, attrs) do
    revision
    |> cast(attrs, [
      :part_number,
      :height_units,
      :width_mm,
      :depth_mm,
      :weight_kg,
      :airflow,
      :specifications
    ])
    |> update_change(:part_number, &normalize_optional_string/1)
    |> validate_length(:part_number, max: 255)
    |> validate_number(:height_units, greater_than: 0, less_than_or_equal_to: @max_integer)
    |> validate_number(:width_mm, greater_than: 0, less_than_or_equal_to: @max_dimension)
    |> validate_number(:depth_mm, greater_than: 0, less_than_or_equal_to: @max_dimension)
    |> validate_number(:weight_kg, greater_than: 0, less_than_or_equal_to: @max_weight)
    |> validate_inclusion(:airflow, @airflows)
    |> validate_map(:specifications)
  end

  defp reject_mutation(%Ecto.Changeset{data: %{id: id}, changes: changes} = changeset)
       when not is_nil(id) and map_size(changes) > 0 do
    add_error(changeset, :base, "catalog revision is immutable")
  end

  defp reject_mutation(changeset), do: changeset

  defp validate_map(changeset, field) do
    validate_change(changeset, field, fn ^field, value ->
      if is_map(value), do: [], else: [{field, "must be a map"}]
    end)
  end

  defp normalize_optional_string(value) do
    case String.trim(value) do
      "" -> nil
      value -> value
    end
  end
end
