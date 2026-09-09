defmodule Renga.Topology.DesiredInterfaceVlanMode do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec, autogenerate: {Renga.Time, :utc_now_ms, []}]

  schema "desired_interface_vlan_modes" do
    field :mode, :string
    field :metadata, :map, default: %{}
    belongs_to :organization, Renga.Accounts.Organization
    belongs_to :interface, Renga.Inventory.Interface
    timestamps()
  end

  def changeset(configuration, attrs) do
    configuration
    |> cast(attrs, [:mode, :metadata])
    |> validate_required([:organization_id, :interface_id, :mode, :metadata])
    |> validate_inclusion(:mode, ~w(access trunk tagged_all))
    |> assoc_constraint(:interface, name: :desired_interface_vlan_modes_tenant_interface_fkey)
    |> unique_constraint([:organization_id, :interface_id])
  end
end
