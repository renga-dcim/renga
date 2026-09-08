defmodule Renga.Topology.DesiredInterfaceVlanAssignment do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec, autogenerate: {Renga.Time, :utc_now_ms, []}]

  schema "desired_interface_vlan_assignments" do
    field :tagging_mode, :string
    field :metadata, :map, default: %{}
    belongs_to :organization, Renga.Accounts.Organization
    belongs_to :interface, Renga.Inventory.Interface
    belongs_to :vlan, Renga.Topology.Vlan
    timestamps()
  end

  def changeset(assignment, attrs) do
    assignment
    |> cast(attrs, [:tagging_mode, :metadata])
    |> validate_required([:organization_id, :interface_id, :vlan_id, :tagging_mode, :metadata])
    |> validate_inclusion(:tagging_mode, ~w(tagged untagged))
    |> assoc_constraint(:interface,
      name: :desired_interface_vlan_assignments_tenant_interface_fkey
    )
    |> assoc_constraint(:vlan, name: :desired_interface_vlan_assignments_tenant_vlan_fkey)
    |> unique_constraint([:organization_id, :interface_id, :vlan_id],
      name: :desired_interface_vlan_assignments_interface_vlan_index
    )
    |> unique_constraint([:organization_id, :interface_id],
      name: :desired_interface_vlan_assignments_effective_untagged_index
    )
  end
end
