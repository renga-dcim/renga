defmodule Renga.Topology.InterfaceNeighborMatch do
  @moduledoc "Current interpretation of a remote endpoint described by neighbor evidence."

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec, autogenerate: {Renga.Time, :utc_now_ms, []}]

  schema "interface_neighbor_matches" do
    field :status, :string
    field :strategy, :string
    field :candidate_count, :integer, default: 0
    belongs_to :organization, Renga.Accounts.Organization
    belongs_to :interface_neighbor_evidence, Renga.Topology.InterfaceNeighborEvidence
    belongs_to :remote_interface, Renga.Inventory.Interface
    timestamps()
  end

  def changeset(match, attrs) do
    match
    |> cast(attrs, [:status, :strategy, :candidate_count, :remote_interface_id])
    |> validate_required([
      :organization_id,
      :interface_neighbor_evidence_id,
      :status,
      :candidate_count
    ])
    |> validate_inclusion(:status, ~w(matched unresolved ambiguous))
    |> validate_inclusion(:strategy, ~w(stable_identifiers name_fallback))
    |> validate_number(:candidate_count, greater_than_or_equal_to: 0)
    |> check_constraint(:strategy, name: :interface_neighbor_matches_valid_strategy)
    |> check_constraint(:remote_interface_id, name: :interface_neighbor_matches_status_shape)
    |> assoc_constraint(:interface_neighbor_evidence,
      name: :interface_neighbor_matches_tenant_evidence_fkey
    )
    |> assoc_constraint(:remote_interface,
      name: :interface_neighbor_matches_tenant_interface_fkey
    )
    |> unique_constraint([:organization_id, :interface_neighbor_evidence_id],
      name: :interface_neighbor_matches_evidence_index
    )
  end
end
