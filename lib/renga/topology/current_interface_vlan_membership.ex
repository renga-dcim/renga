defmodule Renga.Topology.CurrentInterfaceVlanMembership do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec, autogenerate: {Renga.Time, :utc_now_ms, []}]

  schema "current_interface_vlan_memberships" do
    field :tagging_mode, :string
    field :metadata, :map, default: %{}
    belongs_to :organization, Renga.Accounts.Organization
    belongs_to :interface, Renga.Inventory.Interface
    belongs_to :vlan, Renga.Topology.Vlan
    belongs_to :interface_vlan_evidence, Renga.Topology.InterfaceVlanEvidence
    timestamps()
  end

  def changeset(membership, attrs) do
    membership
    |> cast(attrs, [:tagging_mode, :metadata])
    |> validate_required([
      :organization_id,
      :interface_id,
      :vlan_id,
      :interface_vlan_evidence_id,
      :tagging_mode,
      :metadata
    ])
    |> validate_inclusion(:tagging_mode, ~w(tagged untagged))
    |> assoc_constraint(:interface,
      name: :current_interface_vlan_memberships_tenant_interface_fkey
    )
    |> assoc_constraint(:vlan, name: :current_interface_vlan_memberships_tenant_vlan_fkey)
    |> assoc_constraint(:interface_vlan_evidence,
      name: :current_interface_vlan_memberships_tenant_evidence_fkey
    )
    |> unique_constraint([:organization_id, :interface_id, :vlan_id],
      name: :current_interface_vlan_memberships_interface_vlan_index
    )
    |> unique_constraint([:organization_id, :interface_id],
      name: :current_interface_vlan_memberships_effective_untagged_index
    )
  end
end
