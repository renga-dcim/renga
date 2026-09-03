defmodule Renga.Catalog.ComponentTemplate do
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
  @kinds ~w(interface module_bay power_port power_outlet console_port device_bay cpu memory disk)

  schema "component_templates" do
    field :kind, :string
    field :name, :string
    field :label, :string
    field :position, :string
    field :description, :string
    field :required, :boolean, default: true
    field :attributes, :map, default: %{}
    belongs_to :organization, Renga.Accounts.Organization
    belongs_to :catalog_type_revision, Renga.Catalog.TypeRevision
    timestamps()
  end

  def changeset(template, attrs) do
    template
    |> input_changeset(attrs)
    |> reject_mutation()
    |> validate_required([:organization_id, :catalog_type_revision_id])
    |> assoc_constraint(:catalog_type_revision, name: :component_templates_revision_fkey)
    |> check_constraint(:catalog_type_revision,
      name: :component_templates_revision_finalized,
      message: "is finalized"
    )
    |> unique_constraint(:name, name: :component_templates_identity_index)
  end

  def input_changeset(template, attrs) do
    template
    |> cast(attrs, [:kind, :name, :label, :position, :description, :required, :attributes])
    |> update_change(:name, &normalize_string/1)
    |> update_change(:label, &normalize_optional_string/1)
    |> update_change(:position, &normalize_optional_string/1)
    |> update_change(:description, &normalize_optional_string/1)
    |> validate_required([:kind, :name, :required])
    |> validate_text(:name, 255)
    |> validate_text(:label, 255)
    |> validate_text(:position, 255)
    |> validate_text(:description)
    |> validate_inclusion(:kind, @kinds)
    |> validate_jsonb_map(:attributes)
  end

  defp reject_mutation(%Ecto.Changeset{data: %{id: id}, changes: changes} = changeset)
       when not is_nil(id) and map_size(changes) > 0 do
    add_error(changeset, :base, "component template is immutable")
  end

  defp reject_mutation(changeset), do: changeset

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

  defp normalize_string(value) do
    if String.valid?(value), do: String.trim(value), else: value
  end

  defp validate_text(changeset, field, max_length \\ nil) do
    validate_change(changeset, field, fn ^field, value ->
      cond do
        not String.valid?(value) or String.contains?(value, <<0>>) ->
          [{field, "contains characters PostgreSQL text cannot represent"}]

        max_length && codepoint_length(value) > max_length ->
          [{field, {"should be at most %{count} character(s)", [count: max_length]}}]

        true ->
          []
      end
    end)
  end

  defp codepoint_length(value), do: value |> String.codepoints() |> length()
end
