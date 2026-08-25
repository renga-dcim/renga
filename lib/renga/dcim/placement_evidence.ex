defmodule Renga.DCIM.PlacementEvidence do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec, autogenerate: {Renga.Time, :utc_now_ms, []}]

  schema "placement_evidence" do
    field :site_identifier, :string
    field :location_identifier, :string
    field :rack_identifier, :string
    field :position, :integer
    field :height_units, :integer
    field :face, :string
    field :confidence, :integer, default: 50
    field :observed_at, :utc_datetime_usec
    field :stale_at, :utc_datetime_usec
    field :metadata, :map, default: %{}
    belongs_to :organization, Renga.Accounts.Organization
    belongs_to :source, Renga.Inventory.Source
    belongs_to :observation, Renga.Inventory.Observation
    belongs_to :resource, Renga.Inventory.Resource
    timestamps(updated_at: false)
  end

  def changeset(evidence, attrs) do
    evidence
    |> cast(attrs, [
      :site_identifier,
      :location_identifier,
      :rack_identifier,
      :position,
      :height_units,
      :face,
      :confidence,
      :observed_at,
      :stale_at,
      :metadata
    ])
    |> validate_required([
      :organization_id,
      :source_id,
      :observation_id,
      :resource_id,
      :confidence,
      :observed_at
    ])
    |> validate_number(:confidence, greater_than_or_equal_to: 0, less_than_or_equal_to: 100)
    |> validate_number(:position, greater_than: 0)
    |> validate_number(:height_units, greater_than: 0)
    |> validate_inclusion(:face, ~w(front rear full), allow_nil: true)
    |> assoc_constraint(:resource, name: :placement_evidence_resource_fkey)
    |> foreign_key_constraint(:observation_id, name: :placement_evidence_source_observation_fkey)
  end
end
