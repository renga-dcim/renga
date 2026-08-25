defmodule Renga.Catalog.ModuleBay do
  @moduledoc """
  Stable module slot subordinate to a physical device or tracked module.

  Compatibility is explicit. A bay with no compatible module types accepts no
  desired or current installation.
  """

  use Ecto.Schema

  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec, autogenerate: {Renga.Time, :utc_now_ms, []}]
  @statuses ~w(active disabled failed retired)

  schema "module_bays" do
    field :owner_kind, :string
    field :name, :string
    field :label, :string
    field :position, :string
    field :status, :string, default: "active"
    field :metadata, :map, default: %{}
    belongs_to :organization, Renga.Accounts.Organization
    belongs_to :owner_resource, Renga.Inventory.Resource

    many_to_many :compatible_module_types, Renga.Catalog.ModuleType,
      join_through: "module_bay_compatible_types",
      join_keys: [module_bay_id: :id, module_type_id: :id]

    timestamps()
  end

  def changeset(bay, attrs) do
    bay
    |> cast(attrs, [:name, :label, :position, :status, :metadata])
    |> update_change(:name, fn
      value when is_binary(value) -> String.trim(value)
      value -> value
    end)
    |> trim_optional(:label)
    |> trim_optional(:position)
    |> validate_required([
      :organization_id,
      :owner_resource_id,
      :owner_kind,
      :name,
      :status
    ])
    |> validate_inclusion(:status, @statuses)
    |> validate_map(:metadata)
    |> assoc_constraint(:owner_resource, name: :module_bays_owner_resource_fkey)
    |> check_constraint(:owner_kind, name: :module_bays_valid_owner_kind)
    |> unique_constraint(:name, name: :module_bays_owner_name_index)
  end

  defp trim_optional(changeset, field) do
    update_change(changeset, field, fn
      value when is_binary(value) -> value |> String.trim() |> empty_to_nil()
      value -> value
    end)
  end

  defp empty_to_nil(""), do: nil
  defp empty_to_nil(value), do: value

  defp validate_map(changeset, field) do
    validate_change(changeset, field, fn ^field, value ->
      if is_map(value), do: [], else: [{field, "must be a map"}]
    end)
  end
end
