defmodule Renga.Catalog.ModuleType do
  use Ecto.Schema

  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec, autogenerate: {Renga.Time, :utc_now_ms, []}]
  @module_classes ~w(line_card supervisor power_supply fan_tray transceiver other)

  schema "module_types" do
    field :model, :string
    field :module_class, :string
    field :description, :string
    field :metadata, :map, default: %{}
    belongs_to :organization, Renga.Accounts.Organization
    belongs_to :resource, Renga.Inventory.Resource
    belongs_to :manufacturer, Renga.Catalog.Manufacturer
    has_many :revisions, Renga.Catalog.TypeRevision
    timestamps()
  end

  def changeset(module_type, attrs) do
    module_type
    |> cast(attrs, [:manufacturer_id, :model, :module_class, :description, :metadata])
    |> update_change(:model, &String.trim/1)
    |> validate_required([
      :organization_id,
      :resource_id,
      :manufacturer_id,
      :model,
      :module_class
    ])
    |> validate_inclusion(:module_class, @module_classes)
    |> validate_map(:metadata)
    |> assoc_constraint(:resource, name: :module_types_organization_resource_fkey)
    |> assoc_constraint(:manufacturer, name: :module_types_organization_manufacturer_fkey)
    |> unique_constraint(:model,
      name: :module_types_organization_manufacturer_model_index
    )
  end

  defp validate_map(changeset, field) do
    validate_change(changeset, field, fn ^field, value ->
      if is_map(value), do: [], else: [{field, "must be a map"}]
    end)
  end
end
