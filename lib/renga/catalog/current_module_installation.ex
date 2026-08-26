defmodule Renga.Catalog.CurrentModuleInstallation do
  use Ecto.Schema

  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec, autogenerate: {Renga.Time, :utc_now_ms, []}]

  schema "current_module_installations" do
    field :installed_at, :utc_datetime_usec
    field :metadata, :map, default: %{}
    belongs_to :organization, Renga.Accounts.Organization
    belongs_to :module_bay, Renga.Catalog.ModuleBay
    belongs_to :module, Renga.Catalog.Module
    belongs_to :module_type, Renga.Catalog.ModuleType
    timestamps()
  end

  def changeset(installation, attrs) do
    installation
    |> cast(attrs, [:installed_at, :metadata])
    |> validate_required([
      :organization_id,
      :module_bay_id,
      :module_id,
      :module_type_id,
      :installed_at
    ])
    |> validate_map(:metadata)
    |> assoc_constraint(:module_bay, name: :current_module_installations_compatibility_fkey)
    |> assoc_constraint(:module, name: :current_module_installations_module_fkey)
    |> unique_constraint([:organization_id, :module_bay_id],
      name: :current_module_installations_bay_index
    )
    |> unique_constraint([:organization_id, :module_id],
      name: :current_module_installations_module_index
    )
  end

  defp validate_map(changeset, field) do
    validate_change(changeset, field, fn ^field, value ->
      if is_map(value), do: [], else: [{field, "must be a map"}]
    end)
  end
end
