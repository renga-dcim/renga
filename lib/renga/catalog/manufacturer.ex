defmodule Renga.Catalog.Manufacturer do
  use Ecto.Schema

  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec, autogenerate: {Renga.Time, :utc_now_ms, []}]

  schema "manufacturers" do
    field :slug, :string
    field :description, :string
    field :metadata, :map, default: %{}
    belongs_to :organization, Renga.Accounts.Organization
    belongs_to :resource, Renga.Inventory.Resource
    has_many :hardware_types, Renga.Catalog.HardwareType
    has_many :module_types, Renga.Catalog.ModuleType
    timestamps()
  end

  def changeset(manufacturer, attrs) do
    manufacturer
    |> cast(attrs, [:slug, :description, :metadata])
    |> update_change(:slug, &(&1 |> String.trim() |> String.downcase()))
    |> validate_required([:organization_id, :resource_id, :slug])
    |> validate_format(:slug, ~r/^[a-z0-9]+(?:-[a-z0-9]+)*$/)
    |> validate_map(:metadata)
    |> validate_aliases()
    |> assoc_constraint(:resource, name: :manufacturers_organization_resource_fkey)
    |> unique_constraint([:organization_id, :slug])
  end

  defp validate_map(changeset, field) do
    validate_change(changeset, field, fn ^field, value ->
      if is_map(value), do: [], else: [{field, "must be a map"}]
    end)
  end

  defp validate_aliases(changeset) do
    validate_change(changeset, :metadata, fn :metadata, metadata ->
      case Map.fetch(metadata, "aliases") do
        :error ->
          []

        {:ok, aliases} when is_list(aliases) ->
          if Enum.all?(aliases, &(is_binary(&1) and String.trim(&1) != "")),
            do: [],
            else: [metadata: "aliases must contain only non-empty strings"]

        {:ok, _invalid} ->
          [metadata: "aliases must be a list of strings"]
      end
    end)
  end
end
