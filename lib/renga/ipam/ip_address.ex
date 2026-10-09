defmodule Renga.IPAM.IpAddress do
  @moduledoc """
  One managed host address in the global table or a VRF (RFD 4, "Managed
  addresses and assignments"). It replaces the RFD 8 managed address.

  The address keeps its intended prefix length, but identity is the host:
  one managed address per namespace and host value, so `192.0.2.10/24` and
  `192.0.2.10/32` are the same address. Its `ip_address` resource envelope
  owns lifecycle; a retired address is history, not current intent.

  Allocation state, management mode, and role are deliberately independent:
  a reserved address can be a VIP, and an allocated one can be handed out by
  DHCP. A nil management mode means it is not known.
  """
  use Ecto.Schema

  import Ecto.Changeset

  alias Renga.Accounts.Organization
  alias Renga.Accounts.User
  alias Renga.Inventory.Resource
  alias Renga.IPAM.IpAddressAssignment
  alias Renga.IPAM.Vrf
  alias Renga.Types.Inet

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @allocation_states ~w(allocated reserved)
  @management_modes ~w(static dhcp slaac)
  @roles ~w(ordinary loopback secondary vip anycast vrrp hsrp glbp carp)
  @timestamps_opts [type: :utc_datetime_usec, autogenerate: {Renga.Time, :utc_now_ms, []}]

  schema "ip_addresses" do
    field :address, Inet
    field :allocation_state, :string, default: "allocated"
    field :management_mode, :string
    field :role, :string, default: "ordinary"
    field :dns_name, :string
    field :description, :string
    field :metadata, :map, default: %{}

    belongs_to :organization, Organization
    belongs_to :resource, Resource
    belongs_to :vrf, Vrf
    belongs_to :adopted_by, User
    has_many :assignments, IpAddressAssignment

    timestamps()
  end

  def changeset(ip_address, attrs) do
    ip_address
    |> cast(attrs, [
      :address,
      :vrf_id,
      :allocation_state,
      :management_mode,
      :role,
      :dns_name,
      :description
    ])
    |> update_change(:dns_name, &trim/1)
    |> validate_required([:organization_id, :resource_id, :address, :allocation_state, :role])
    |> validate_inclusion(:allocation_state, @allocation_states)
    |> validate_inclusion(:management_mode, @management_modes)
    |> validate_inclusion(:role, @roles)
    |> validate_length(:dns_name, max: 253)
    |> validate_length(:description, max: 255)
    |> assoc_constraint(:resource, name: :ip_addresses_organization_resource_fkey)
    |> foreign_key_constraint(:vrf_id, name: :ip_addresses_tenant_vrf_fkey)
    |> unique_constraint([:organization_id, :resource_id])
    |> unique_constraint(:address,
      name: :ip_addresses_namespace_host_index,
      message: "is already managed in this routing table"
    )
    |> check_constraint(:allocation_state, name: :ip_addresses_valid_allocation_state)
    |> check_constraint(:management_mode, name: :ip_addresses_valid_management_mode)
    |> check_constraint(:role, name: :ip_addresses_valid_role)
  end

  def allocation_states, do: @allocation_states
  def management_modes, do: @management_modes
  def roles, do: @roles

  defp trim(nil), do: nil
  defp trim(value), do: String.trim(value)
end
