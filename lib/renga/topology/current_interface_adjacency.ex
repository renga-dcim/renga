defmodule Renga.Topology.CurrentInterfaceAdjacency do
  @moduledoc "Canonical current Layer 2 adjacency selected from active neighbor evidence."

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec, autogenerate: {Renga.Time, :utc_now_ms, []}]

  schema "current_interface_adjacencies" do
    field :confidence, :string
    field :last_observed_at, :utc_datetime_usec
    field :metadata, :map, default: %{}
    belongs_to :organization, Renga.Accounts.Organization
    belongs_to :interface_a, Renga.Inventory.Interface
    belongs_to :interface_b, Renga.Inventory.Interface
    belongs_to :primary_evidence, Renga.Topology.InterfaceNeighborEvidence
    timestamps()
  end

  def changeset(adjacency, attrs) do
    adjacency
    |> cast(attrs, [:confidence, :last_observed_at, :metadata])
    |> validate_required([
      :organization_id,
      :interface_a_id,
      :interface_b_id,
      :primary_evidence_id,
      :confidence,
      :last_observed_at,
      :metadata
    ])
    |> validate_inclusion(:confidence, ~w(reported reciprocal))
    |> check_constraint(:interface_b_id, name: :current_interface_adjacencies_canonical_order)
    |> assoc_constraint(:interface_a, name: :current_interface_adjacencies_tenant_a_fkey)
    |> assoc_constraint(:interface_b, name: :current_interface_adjacencies_tenant_b_fkey)
    |> assoc_constraint(:primary_evidence,
      name: :current_interface_adjacencies_tenant_evidence_fkey
    )
    |> unique_constraint([:organization_id, :interface_a_id, :interface_b_id],
      name: :current_interface_adjacencies_endpoints_index
    )
  end
end
