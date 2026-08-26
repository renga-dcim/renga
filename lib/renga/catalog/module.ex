defmodule Renga.Catalog.Module do
  @moduledoc """
  Independently tracked replaceable module with a resource envelope.

  The immutable catalog revision is pinned when the module is created so later
  type revisions cannot silently rewrite the module's expected structure.
  """

  use Ecto.Schema

  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec, autogenerate: {Renga.Time, :utc_now_ms, []}]
  @statuses ~w(active spare failed retired unknown)

  schema "modules" do
    field :status, :string, default: "unknown"
    field :serial_number, :string
    field :part_number, :string
    field :asset_tag, :string
    field :metadata, :map, default: %{}
    belongs_to :organization, Renga.Accounts.Organization
    belongs_to :resource, Renga.Inventory.Resource
    belongs_to :module_type, Renga.Catalog.ModuleType
    belongs_to :catalog_type_revision, Renga.Catalog.TypeRevision
    timestamps()
  end

  def changeset(module, attrs) do
    module
    |> cast(attrs, [:status, :serial_number, :part_number, :asset_tag, :metadata])
    |> trim_optional(:serial_number)
    |> trim_optional(:part_number)
    |> trim_optional(:asset_tag)
    |> validate_required([
      :organization_id,
      :resource_id,
      :module_type_id,
      :catalog_type_revision_id,
      :status
    ])
    |> validate_inclusion(:status, @statuses)
    |> validate_map(:metadata)
    |> assoc_constraint(:resource, name: :modules_resource_fkey)
    |> assoc_constraint(:module_type, name: :modules_module_type_fkey)
    |> assoc_constraint(:catalog_type_revision, name: :modules_revision_fkey)
    |> unique_constraint([:organization_id, :resource_id])
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
