defmodule Renga.Inventory.InterfaceRelationshipEvidence do
  @moduledoc """
  Observation-scoped source evidence for typed interface topology.

  Topology remains canonical and source-neutral while each collector assertion
  is retained for conflict handling and stale evidence cleanup.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias Renga.Accounts.Organization
  alias Renga.Inventory.InterfaceRelationship
  alias Renga.Inventory.Observation
  alias Renga.Inventory.Source

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @kinds ~w(parent lower_device lag_member bridge_member bridged peer vrf_member backed_by)
  @timestamps_opts [type: :utc_datetime_usec, autogenerate: {Renga.Time, :utc_now_ms, []}]

  schema "interface_relationship_evidence" do
    field :kind, :string
    field :metadata, :map, default: %{}
    field :observed_at, :utc_datetime_usec

    belongs_to :organization, Organization
    belongs_to :interface_relationship, InterfaceRelationship
    belongs_to :source, Source
    belongs_to :observation, Observation

    timestamps()
  end

  def changeset(evidence, attrs) do
    evidence
    |> cast(attrs, [:kind, :metadata, :observed_at])
    |> validate_required([
      :organization_id,
      :interface_relationship_id,
      :source_id,
      :observation_id,
      :kind,
      :observed_at
    ])
    |> validate_inclusion(:kind, @kinds)
    |> assoc_constraint(:organization)
    |> assoc_constraint(:interface_relationship)
    |> assoc_constraint(:source)
    |> assoc_constraint(:observation)
    |> unique_constraint([:organization_id, :observation_id, :interface_relationship_id],
      name: :interface_relationship_evidence_observation_link_index
    )
  end
end
