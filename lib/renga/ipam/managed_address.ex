defmodule Renga.IPAM.ManagedAddress do
  @moduledoc """
  An address an operator adopted into managed state (RFD 8, "Prefixes").

  Observed addresses are normal on their own and never findings; a managed
  address is the explicit decision that one needs state of its own, such as
  a description, that outlives its observation. The interface remembers
  where it was adopted from and is cleared if that interface is deleted.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias Renga.Types.Inet

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec, autogenerate: {Renga.Time, :utc_now_ms, []}]

  schema "managed_addresses" do
    field :address, Inet
    field :description, :string
    belongs_to :organization, Renga.Accounts.Organization
    belongs_to :interface, Renga.Inventory.Interface
    belongs_to :adopted_by, Renga.Accounts.User

    timestamps()
  end

  def changeset(managed, attrs) do
    managed
    |> cast(attrs, [:description])
    |> validate_required([:organization_id, :address])
    |> validate_length(:description, max: 255)
    |> assoc_constraint(:interface, name: :managed_addresses_tenant_interface_fkey)
    |> unique_constraint(:address,
      name: :managed_addresses_organization_address_index,
      message: "is already managed"
    )
  end
end
