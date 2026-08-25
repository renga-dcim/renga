defmodule Renga.Catalog.InventoryItem do
  @moduledoc """
  Tracked physical part subordinate to one inventory resource.

  Inventory items describe assembly and asset structure only. Parts that become
  topology endpoints or independently managed assets are promoted explicitly
  rather than acquiring hidden graph behavior through metadata.
  """

  use Ecto.Schema

  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec, autogenerate: {Renga.Time, :utc_now_ms, []}]
  @kinds ~w(dimm cpu disk fan power_supply battery fru other)
  @statuses ~w(installed spare removed failed unknown)

  schema "inventory_items" do
    field :name, :string
    field :kind, :string
    field :status, :string, default: "unknown"
    field :position, :string
    field :serial_number, :string
    field :part_number, :string
    field :asset_tag, :string
    field :metadata, :map, default: %{}
    belongs_to :organization, Renga.Accounts.Organization
    belongs_to :owner_resource, Renga.Inventory.Resource
    belongs_to :parent, __MODULE__
    belongs_to :promoted_module, Renga.Catalog.Module
    has_many :children, __MODULE__, foreign_key: :parent_id
    timestamps()
  end

  def changeset(item, attrs) do
    item
    |> cast(attrs, [
      :parent_id,
      :name,
      :kind,
      :status,
      :position,
      :serial_number,
      :part_number,
      :asset_tag,
      :metadata
    ])
    |> update_change(:name, fn
      value when is_binary(value) -> String.trim(value)
      value -> value
    end)
    |> trim_optional(:position)
    |> trim_optional(:serial_number)
    |> trim_optional(:part_number)
    |> trim_optional(:asset_tag)
    |> validate_required([:organization_id, :owner_resource_id, :name, :kind, :status])
    |> validate_inclusion(:kind, @kinds)
    |> validate_inclusion(:status, @statuses)
    |> validate_map(:metadata)
    |> assoc_constraint(:owner_resource, name: :inventory_items_owner_resource_fkey)
    |> assoc_constraint(:parent, name: :inventory_items_owner_parent_fkey)
    |> check_constraint(:parent_id, name: :inventory_items_not_self_parent)
    |> unique_constraint(:name, name: :inventory_items_owner_name_index)
  end

  def promotion_changeset(item, module_id) do
    item
    |> change(promoted_module_id: module_id)
    |> assoc_constraint(:promoted_module, name: :inventory_items_promoted_module_fkey)
    |> unique_constraint(:promoted_module_id, name: :inventory_items_promoted_module_index)
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
