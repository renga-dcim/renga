defmodule Renga.Catalog.ModuleBayCompatibleType do
  use Ecto.Schema

  import Ecto.Changeset

  @primary_key false
  @foreign_key_type :binary_id
  @timestamps_opts [
    type: :utc_datetime_usec,
    autogenerate: {Renga.Time, :utc_now_ms, []},
    updated_at: false
  ]

  schema "module_bay_compatible_types" do
    belongs_to :organization, Renga.Accounts.Organization
    belongs_to :module_bay, Renga.Catalog.ModuleBay, primary_key: true
    belongs_to :module_type, Renga.Catalog.ModuleType, primary_key: true
    timestamps()
  end

  def changeset(compatibility, attrs \\ %{}) do
    compatibility
    |> cast(attrs, [])
    |> validate_required([:organization_id, :module_bay_id, :module_type_id])
    |> assoc_constraint(:module_bay, name: :module_bay_compatible_types_bay_fkey)
    |> assoc_constraint(:module_type, name: :module_bay_compatible_types_type_fkey)
    |> unique_constraint([:module_bay_id, :module_type_id],
      name: :module_bay_compatible_types_pkey
    )
  end
end
