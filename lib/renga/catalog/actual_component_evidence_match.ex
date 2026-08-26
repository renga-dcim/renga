defmodule Renga.Catalog.ActualComponentEvidenceMatch do
  @moduledoc "Reconciliation link from immutable source evidence to a canonical component."

  use Ecto.Schema

  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @strategies ~w(discovered serial_number provider_id position_part_number)
  @timestamps_opts [
    type: :utc_datetime_usec,
    autogenerate: {Renga.Time, :utc_now_ms, []},
    updated_at: false
  ]

  schema "actual_component_evidence_matches" do
    field :match_strategy, :string
    belongs_to :organization, Renga.Accounts.Organization
    belongs_to :owner_resource, Renga.Inventory.Resource
    belongs_to :actual_component, Renga.Catalog.ActualComponent
    belongs_to :component_evidence, Renga.Inventory.ComponentEvidence
    timestamps()
  end

  def changeset(match, attrs) do
    match
    |> cast(attrs, [:match_strategy])
    |> validate_required([
      :organization_id,
      :owner_resource_id,
      :actual_component_id,
      :component_evidence_id,
      :match_strategy
    ])
    |> validate_inclusion(:match_strategy, @strategies)
    |> assoc_constraint(:actual_component,
      name: :actual_component_evidence_matches_component_fkey
    )
    |> assoc_constraint(:component_evidence,
      name: :actual_component_evidence_matches_evidence_fkey
    )
    |> unique_constraint(:component_evidence_id,
      name: :actual_component_evidence_matches_evidence_index
    )
  end
end
