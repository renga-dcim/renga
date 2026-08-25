defmodule Renga.DCIM.PlacementFinding do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec, autogenerate: {Renga.Time, :utc_now_ms, []}]
  @kinds ~w(unknown_location ambiguous_identifier containment_conflict source_disagreement catalog_height_mismatch confirmed_placement_conflict multiple_current_placements blocked_move)

  schema "placement_findings" do
    field :kind, :string
    field :status, :string, default: "open"
    field :message, :string
    field :details, :map, default: %{}
    field :resolved_at, :utc_datetime_usec
    belongs_to :organization, Renga.Accounts.Organization
    belongs_to :resource, Renga.Inventory.Resource
    timestamps()
  end

  def changeset(finding, attrs) do
    finding
    |> cast(attrs, [:kind, :status, :message, :details, :resolved_at])
    |> validate_required([:organization_id, :resource_id, :kind, :status, :message])
    |> validate_inclusion(:kind, @kinds)
    |> validate_inclusion(:status, ~w(open resolved))
    |> assoc_constraint(:resource, name: :placement_findings_resource_fkey)
    |> unique_constraint([:organization_id, :resource_id, :kind],
      name: :placement_findings_open_kind_index
    )
  end
end
