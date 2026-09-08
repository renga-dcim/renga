defmodule Renga.Topology.InterfaceVlanEvidence do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec, autogenerate: {Renga.Time, :utc_now_ms, []}]

  schema "interface_vlan_evidence" do
    field :source_local_key, :string
    field :source_local_scope, :string
    field :vid, :integer
    field :tagging_mode, :string
    field :metadata, :map, default: %{}
    field :observed_at, :utc_datetime_usec
    field :stale_at, :utc_datetime_usec
    belongs_to :organization, Renga.Accounts.Organization
    belongs_to :interface, Renga.Inventory.Interface
    belongs_to :vlan, Renga.Topology.Vlan
    belongs_to :source, Renga.Inventory.Source
    belongs_to :observation, Renga.Inventory.Observation
    timestamps(updated_at: false)
  end

  def changeset(evidence, attrs) do
    evidence
    |> cast(attrs, [
      :source_local_key,
      :source_local_scope,
      :vid,
      :tagging_mode,
      :metadata,
      :observed_at,
      :stale_at
    ])
    |> validate_required([
      :organization_id,
      :interface_id,
      :source_id,
      :observation_id,
      :source_local_key,
      :vid,
      :tagging_mode,
      :metadata,
      :observed_at
    ])
    |> validate_number(:vid, greater_than_or_equal_to: 1, less_than_or_equal_to: 4094)
    |> validate_inclusion(:tagging_mode, ~w(tagged untagged))
    |> assoc_constraint(:interface, name: :interface_vlan_evidence_tenant_interface_fkey)
    |> assoc_constraint(:vlan, name: :interface_vlan_evidence_tenant_vlan_fkey)
    |> assoc_constraint(:source, name: :interface_vlan_evidence_tenant_source_fkey)
    |> assoc_constraint(:observation, name: :interface_vlan_evidence_tenant_observation_fkey)
    |> unique_constraint([:organization_id, :observation_id, :interface_id, :source_local_key],
      name: :interface_vlan_evidence_observation_link_index
    )
  end
end
