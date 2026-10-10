defmodule Renga.IPAM.IpAddressAssignment do
  @moduledoc """
  A managed address's intended interface (RFD 4, "Managed addresses and
  assignments").

  Assignments are separate rows so an address can be reserved or unassigned,
  assigned to one interface, or, when its role allows sharing, to several.
  Both sides are tenant-checked by composite foreign keys, a pair cannot be
  assigned twice, and the assignment goes with its interface while the
  managed address stays.
  """
  use Ecto.Schema

  import Ecto.Changeset

  alias Renga.Accounts.Organization
  alias Renga.Accounts.User
  alias Renga.Inventory.Interface
  alias Renga.IPAM.IpAddress

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec, autogenerate: {Renga.Time, :utc_now_ms, []}]

  schema "ip_address_assignments" do
    belongs_to :organization, Organization
    belongs_to :ip_address, IpAddress
    belongs_to :interface, Interface
    belongs_to :assigned_by, User

    timestamps()
  end

  def changeset(assignment) do
    assignment
    |> change()
    |> validate_required([:organization_id, :ip_address_id, :interface_id])
    |> foreign_key_constraint(:ip_address_id,
      name: :ip_address_assignments_tenant_ip_address_fkey
    )
    |> foreign_key_constraint(:interface_id, name: :ip_address_assignments_tenant_interface_fkey)
    |> unique_constraint(:interface_id,
      name: :ip_address_assignments_address_interface_index,
      message: "already has this address"
    )
  end
end
