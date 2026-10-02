defmodule Renga.Topology.PrefixVlanRelationship do
  @moduledoc """
  Optional explicit association between an IPAM prefix and a VLAN.

  Neither side owns the other: a prefix works without a VLAN and a VLAN works
  without a prefix. The association only records that an operator linked the
  two; VRF membership, L2 scope, and name or VID coincidences stay unrelated.
  """

  use Ecto.Schema

  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec, autogenerate: {Renga.Time, :utc_now_ms, []}]

  schema "prefix_vlan_relationships" do
    belongs_to :organization, Renga.Accounts.Organization
    belongs_to :prefix, Renga.Inventory.Prefix
    belongs_to :vlan, Renga.Topology.Vlan

    timestamps()
  end

  def changeset(relationship, attrs) do
    relationship
    |> cast(attrs, [])
    |> validate_required([:organization_id, :prefix_id, :vlan_id])
    |> assoc_constraint(:prefix, name: :prefix_vlan_relationships_tenant_prefix_fkey)
    |> assoc_constraint(:vlan, name: :prefix_vlan_relationships_tenant_vlan_fkey)
    |> unique_constraint([:organization_id, :prefix_id, :vlan_id],
      name: :prefix_vlan_relationships_prefix_vlan_index,
      error_key: :vlan_id
    )
  end
end
