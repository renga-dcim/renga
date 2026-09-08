defmodule Renga.Topology.SourceVlanGroupMapping do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec, autogenerate: {Renga.Time, :utc_now_ms, []}]

  schema "source_vlan_group_mappings" do
    field :source_local_scope, :string, default: "default"
    field :metadata, :map, default: %{}
    belongs_to :organization, Renga.Accounts.Organization
    belongs_to :source, Renga.Inventory.Source
    belongs_to :vlan_group, Renga.Topology.VlanGroup
    timestamps()
  end

  def changeset(mapping, attrs) do
    mapping
    |> cast(attrs, [:source_local_scope, :metadata])
    |> update_change(:source_local_scope, &String.trim/1)
    |> validate_required([:organization_id, :source_id, :source_local_scope, :metadata])
    |> validate_length(:source_local_scope, min: 1, max: 255)
    |> assoc_constraint(:source, name: :source_vlan_group_mappings_tenant_source_fkey)
    |> assoc_constraint(:vlan_group, name: :source_vlan_group_mappings_tenant_group_fkey)
    |> unique_constraint([:organization_id, :source_id, :source_local_scope],
      name: :source_vlan_group_mappings_source_scope_index
    )
  end
end
