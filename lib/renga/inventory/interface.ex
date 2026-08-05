defmodule Renga.Inventory.Interface do
  @moduledoc """
  First-class network interface observed on an inventory resource.

  Interfaces are separate records so MAC addresses, IP addresses, link state,
  and future switch-port relationships can be queried without unpacking JSON
  metadata from a host observation.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias Renga.Accounts.Organization
  alias Renga.Inventory.Address
  alias Renga.Inventory.InterfaceRelationship
  alias Renga.Inventory.Resource
  alias Renga.Types.MacAddress

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @kinds ~w(ethernet loopback bond bridge vlan virtual unknown)
  @statuses ~w(up down dormant not_present unknown)
  @timestamps_opts [type: :utc_datetime_usec, autogenerate: {Renga.Time, :utc_now_ms, []}]

  schema "interfaces" do
    field :name, :string
    field :mac_address, MacAddress
    field :kind, :string, default: "ethernet"
    field :status, :string, default: "unknown"
    field :mtu, :integer
    field :speed_mbps, :integer
    field :metadata, :map, default: %{}
    belongs_to :organization, Organization
    belongs_to :resource, Resource
    has_many :addresses, Address
    has_many :outgoing_relationships, InterfaceRelationship, foreign_key: :source_interface_id
    has_many :incoming_relationships, InterfaceRelationship, foreign_key: :target_interface_id

    timestamps()
  end

  def changeset(interface, attrs) do
    interface
    |> cast(attrs, [
      :name,
      :mac_address,
      :kind,
      :status,
      :mtu,
      :speed_mbps,
      :metadata
    ])
    |> update_change(:name, &String.trim/1)
    |> validate_required([:organization_id, :resource_id, :name, :kind, :status])
    |> validate_inclusion(:kind, @kinds)
    |> validate_inclusion(:status, @statuses)
    |> validate_number(:mtu, greater_than: 0)
    |> validate_number(:speed_mbps, greater_than: 0)
    |> check_constraint(:mtu, name: :interfaces_mtu_speed_positive)
    |> assoc_constraint(:organization)
    |> assoc_constraint(:resource, name: :interfaces_organization_resource_fkey)
    |> unique_constraint([:organization_id, :resource_id, :name])
  end
end
