defmodule Renga.DCIM.RackOccupancy do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec, autogenerate: {Renga.Time, :utc_now_ms, []}]

  schema "rack_occupancies" do
    field :face, :string
    field :units, Renga.Types.Int4Range
    belongs_to :organization, Renga.Accounts.Organization
    belongs_to :current_placement, Renga.DCIM.CurrentPlacement
    belongs_to :rack, Renga.DCIM.Rack
    timestamps()
  end

  def changeset(occupancy, attrs) do
    occupancy
    |> cast(attrs, [:face, :units])
    |> validate_required([:organization_id, :current_placement_id, :rack_id, :face, :units])
    |> validate_inclusion(:face, ~w(front rear))
    |> assoc_constraint(:current_placement, name: :rack_occupancies_placement_fkey)
    |> assoc_constraint(:rack, name: :rack_occupancies_rack_fkey)
    |> exclusion_constraint(:units,
      name: :rack_occupancies_no_overlap,
      message: "overlaps existing rack occupancy"
    )
  end
end
