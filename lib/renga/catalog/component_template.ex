defmodule Renga.Catalog.ComponentTemplate do
  use Ecto.Schema

  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [
    type: :utc_datetime_usec,
    autogenerate: {Renga.Time, :utc_now_ms, []},
    updated_at: false
  ]
  @kinds ~w(interface module_bay power_port power_outlet console_port device_bay)

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
    |> cast(attrs, [:kind, :name, :label, :position, :description, :required, :attributes])
    |> reject_mutation()
    |> update_change(:name, &String.trim/1)
    |> validate_required([
      :organization_id,
      :catalog_type_revision_id,
      :kind,
      :name,
      :required
    ])
    |> validate_inclusion(:kind, @kinds)
    |> validate_map(:attributes)
    |> assoc_constraint(:catalog_type_revision, name: :component_templates_revision_fkey)
    |> check_constraint(:catalog_type_revision,
      name: :component_templates_revision_finalized,
      message: "is finalized"
    )
    |> unique_constraint([:organization_id, :catalog_type_revision_id, :kind, :name])
  end

  defp reject_mutation(%Ecto.Changeset{data: %{id: id}, changes: changes} = changeset)
       when not is_nil(id) and map_size(changes) > 0 do
    add_error(changeset, :base, "component template is immutable")
  end

  defp reject_mutation(changeset), do: changeset

  defp validate_map(changeset, field) do
    validate_change(changeset, field, fn ^field, value ->
      if is_map(value), do: [], else: [{field, "must be a map"}]
    end)
  end
end
