defmodule Renga.Inventory.Address do
  @moduledoc """
  IP address observed on a resource interface.

  Addresses live outside interface metadata so IPAM, stale detection, and
  duplicate-address checks can become normal queries in later phases.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias Renga.Accounts.Organization
  alias Renga.Inventory.Interface
  alias Renga.Inventory.Resource
  alias Renga.Types.Inet

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @kinds ~w(ipv4 ipv6)
  @timestamps_opts [type: :utc_datetime_usec, autogenerate: {Renga.Time, :utc_now_ms, []}]

  schema "addresses" do
    field :kind, :string
    field :address, Inet
    field :scope, :string
    field :metadata, :map, default: %{}
    belongs_to :organization, Organization
    belongs_to :resource, Resource
    belongs_to :interface, Interface

    timestamps()
  end

  def changeset(address, attrs) do
    address
    |> cast(attrs, [
      :kind,
      :address,
      :scope,
      :metadata
    ])
    |> validate_required([:organization_id, :resource_id, :interface_id, :kind, :address])
    |> validate_inclusion(:kind, @kinds)
    |> validate_kind_matches_address()
    |> assoc_constraint(:organization)
    |> assoc_constraint(:resource)
    |> assoc_constraint(:interface)
    |> unique_constraint([:organization_id, :interface_id, :address])
  end

  defp validate_kind_matches_address(changeset) do
    kind = get_field(changeset, :kind)
    address = get_field(changeset, :address)

    if address_family(address) in [nil, kind] do
      changeset
    else
      add_error(changeset, :address, "does not match kind")
    end
  end

  defp address_family(%Postgrex.INET{address: {_, _, _, _}}), do: "ipv4"
  defp address_family(%Postgrex.INET{address: {_, _, _, _, _, _, _, _}}), do: "ipv6"
  defp address_family(_address), do: nil
end
