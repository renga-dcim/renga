defmodule Renga.Catalog.TypeRevision do
  use Ecto.Schema

  import Ecto.Changeset

  alias Renga.Catalog.JSONB

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
    |> validate_text(:part_number, 255)
    |> validate_number(:height_units, greater_than: 0, less_than_or_equal_to: @max_integer)
    |> validate_number(:width_mm, greater_than: 0, less_than_or_equal_to: @max_dimension)
    |> validate_number(:depth_mm, greater_than: 0, less_than_or_equal_to: @max_dimension)
    |> validate_number(:weight_kg, greater_than: 0, less_than_or_equal_to: @max_weight)
    |> validate_decimal_scale(:width_mm, 2)
    |> validate_decimal_scale(:depth_mm, 2)
    |> validate_decimal_scale(:weight_kg, 3)
    |> validate_inclusion(:airflow, @airflows)
    |> validate_jsonb_map(:specifications)
  end

  defp reject_mutation(%Ecto.Changeset{data: %{id: id}, changes: changes} = changeset)
       when not is_nil(id) and map_size(changes) > 0 do
    add_error(changeset, :base, "catalog revision is immutable")
  end

  defp reject_mutation(changeset), do: changeset

  defp validate_decimal_scale(changeset, field, scale) do
    validate_change(changeset, field, fn ^field, value ->
      if Decimal.equal?(value, Decimal.round(value, scale)),
        do: [],
        else: [{field, "must have at most #{scale} decimal places"}]
    end)
  end

  defp validate_jsonb_map(changeset, field) do
    validate_change(changeset, field, fn ^field, value ->
      case JSONB.validate(value) do
        :ok when is_map(value) -> []
        :ok -> [{field, "must be a map"}]
        {:error, message} -> [{field, message}]
      end
    end)
  end

  defp normalize_optional_string(value) do
    if String.valid?(value) do
      case String.trim(value) do
        "" -> nil
        value -> value
      end
    else
      value
    end
  end

  defp validate_text(changeset, field, max_length) do
    validate_change(changeset, field, fn ^field, value ->
      cond do
        not String.valid?(value) or String.contains?(value, <<0>>) ->
          [{field, "contains characters PostgreSQL text cannot represent"}]

        codepoint_length(value) > max_length ->
          [{field, {"should be at most %{count} character(s)", [count: max_length]}}]

        true ->
          []
      end
    end)
  end

  defp codepoint_length(value), do: value |> String.codepoints() |> length()
end
