defmodule Renga.Inventory.InterfaceRelationship do
  @moduledoc """
  Directed relationship between two observed inventory interfaces.

  The source interface points at the target interface with a typed relationship,
  such as a physical NIC being a `lag_member` of a bond or a bond being a
  `bridge_member` of a Linux bridge. Keeping this as a table avoids overloading
  one parent field as host, VM, libvirt, and cloud-hypervisor topology gets more
  graph-shaped.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias Renga.Accounts.Organization
  alias Renga.Inventory.Interface
  alias Renga.Inventory.Source

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @kinds ~w(parent lower_device lag_member bridge_member bridged peer vrf_member backed_by)
  @timestamps_opts [type: :utc_datetime]

  schema "interface_relationships" do
    field :kind, :string
    field :metadata, :map, default: %{}
    field :first_seen_at, :utc_datetime
    field :last_seen_at, :utc_datetime

    belongs_to :organization, Organization
    belongs_to :source_interface, Interface
    belongs_to :target_interface, Interface
    belongs_to :source, Source

    timestamps()
  end

  def changeset(interface_relationship, attrs) do
    interface_relationship
    |> cast(attrs, [:kind, :metadata, :first_seen_at, :last_seen_at])
    |> validate_required([:organization_id, :source_interface_id, :target_interface_id, :kind])
    |> validate_inclusion(:kind, @kinds)
    |> validate_distinct_interfaces()
    |> assoc_constraint(:organization)
    |> assoc_constraint(:source_interface)
    |> assoc_constraint(:target_interface)
    |> assoc_constraint(:source)
    |> unique_constraint(
      [
        :organization_id,
        :source_interface_id,
        :target_interface_id,
        :kind
      ],
      name: :interface_relationships_source_target_kind_index
    )
  end

  defp validate_distinct_interfaces(changeset) do
    source_interface_id = get_field(changeset, :source_interface_id)
    target_interface_id = get_field(changeset, :target_interface_id)

    if source_interface_id && source_interface_id == target_interface_id do
      add_error(changeset, :target_interface_id, "must be different from source interface")
    else
      changeset
    end
  end
end
