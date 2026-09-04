defmodule Renga.Topology.VlanGroupVidRange do
  use Ecto.Schema

  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec, autogenerate: {Renga.Time, :utc_now_ms, []}]

  schema "vlan_group_vid_ranges" do
    field :start_vid, :integer
    field :end_vid, :integer
    belongs_to :organization, Renga.Accounts.Organization
    belongs_to :vlan_group, Renga.Topology.VlanGroup
    timestamps()
  end

  def changeset(range, attrs) do
    range
    |> cast(attrs, [:start_vid, :end_vid])
    |> validate_required([:organization_id, :vlan_group_id, :start_vid, :end_vid])
    |> validate_number(:start_vid, greater_than_or_equal_to: 1, less_than_or_equal_to: 4094)
    |> validate_number(:end_vid, greater_than_or_equal_to: 1, less_than_or_equal_to: 4094)
    |> validate_order()
    |> assoc_constraint(:vlan_group, name: :vlan_group_vid_ranges_group_fkey)
    |> check_constraint(:start_vid, name: :vlan_group_vid_ranges_valid_bounds)
    |> exclusion_constraint(:start_vid,
      name: :vlan_group_vid_ranges_no_overlap,
      message: "overlaps another valid VID range"
    )
  end

  defp validate_order(changeset) do
    start_vid = get_field(changeset, :start_vid)
    end_vid = get_field(changeset, :end_vid)

    if is_integer(start_vid) and is_integer(end_vid) and start_vid > end_vid,
      do: add_error(changeset, :end_vid, "must be greater than or equal to the start VID"),
      else: changeset
  end
end
