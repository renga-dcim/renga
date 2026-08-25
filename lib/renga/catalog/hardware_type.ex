defmodule Renga.Catalog.HardwareType do
  use Ecto.Schema

  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec, autogenerate: {Renga.Time, :utc_now_ms, []}]
  @device_classes ~w(server switch appliance chassis pdu storage other)

  schema "hardware_types" do
    field :model, :string
    field :device_class, :string
    field :description, :string
    field :metadata, :map, default: %{}
    belongs_to :organization, Renga.Accounts.Organization
    belongs_to :resource, Renga.Inventory.Resource
    belongs_to :manufacturer, Renga.Catalog.Manufacturer
    has_many :revisions, Renga.Catalog.TypeRevision
    timestamps()
  end

  def changeset(hardware_type, attrs) do
    hardware_type
    |> cast(attrs, [:manufacturer_id, :model, :device_class, :description, :metadata])
    |> update_change(:model, &String.trim/1)
    |> validate_required([
      :organization_id,
      :resource_id,
      :manufacturer_id,
      :model,
      :device_class
    ])
    |> validate_inclusion(:device_class, @device_classes)
    |> validate_map(:metadata)
    |> assoc_constraint(:resource, name: :hardware_types_organization_resource_fkey)
    |> assoc_constraint(:manufacturer, name: :hardware_types_organization_manufacturer_fkey)
    |> unique_constraint(:model,
      name: :hardware_types_organization_manufacturer_model_index
    )
  end

  defp validate_map(changeset, field) do
    validate_change(changeset, field, fn ^field, value ->
      if is_map(value), do: [], else: [{field, "must be a map"}]
    end)
  end
end
