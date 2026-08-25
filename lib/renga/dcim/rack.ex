defmodule Renga.DCIM.Rack do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec, autogenerate: {Renga.Time, :utc_now_ms, []}]
  @statuses ~w(planned active staging decommissioning retired)

  schema "racks" do
    field :status, :string, default: "active"
    field :facility_id, :string
    field :height_units, :integer, default: 42
    field :width, :string, default: "19_inch"
    field :starting_unit, :string, default: "bottom"
    field :outer_width, :decimal
    field :outer_depth, :decimal
    field :dimension_unit, :string
    field :metadata, :map, default: %{}
    belongs_to :organization, Renga.Accounts.Organization
    belongs_to :resource, Renga.Inventory.Resource
    belongs_to :site, Renga.DCIM.Site
    belongs_to :location, Renga.DCIM.Location
    has_many :occupancies, Renga.DCIM.RackOccupancy
    timestamps()
  end

  def changeset(rack, attrs) do
    rack
    |> cast(attrs, [
      :site_id,
      :location_id,
      :status,
      :facility_id,
      :height_units,
      :width,
      :starting_unit,
      :outer_width,
      :outer_depth,
      :dimension_unit,
      :metadata
    ])
    |> validate_required([
      :organization_id,
      :resource_id,
      :site_id,
      :status,
      :height_units,
      :width,
      :starting_unit
    ])
    |> validate_inclusion(:status, @statuses)
    |> validate_inclusion(:width, ~w(10_inch 19_inch 21_inch 23_inch custom))
    |> validate_inclusion(:starting_unit, ~w(bottom top))
    |> validate_inclusion(:dimension_unit, ~w(mm cm in), allow_nil: true)
    |> validate_number(:height_units, greater_than: 0)
    |> validate_number(:outer_width, greater_than: 0)
    |> validate_number(:outer_depth, greater_than: 0)
    |> check_constraint(:height_units, name: :racks_valid_geometry)
    |> assoc_constraint(:resource, name: :racks_organization_resource_fkey)
    |> assoc_constraint(:site, name: :racks_organization_site_fkey)
    |> assoc_constraint(:location, name: :racks_site_location_fkey)
  end
end
