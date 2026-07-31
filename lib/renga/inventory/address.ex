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
  alias Renga.Inventory.Source

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @kinds ~w(ipv4 ipv6)
  @timestamps_opts [type: :utc_datetime]

  schema "addresses" do
    field :kind, :string
    field :address, :string
    field :prefix_length, :integer
    field :scope, :string
    field :metadata, :map, default: %{}
    field :first_seen_at, :utc_datetime
    field :last_seen_at, :utc_datetime

    belongs_to :organization, Organization
    belongs_to :resource, Resource
    belongs_to :interface, Interface
    belongs_to :source, Source

    timestamps()
  end

  def changeset(address, attrs) do
    address
    |> cast(attrs, [
      :source_id,
      :kind,
      :address,
      :prefix_length,
      :scope,
      :metadata,
      :first_seen_at,
      :last_seen_at
    ])
    |> update_change(:address, &trim_address/1)
    |> validate_required([:organization_id, :resource_id, :interface_id, :kind, :address])
    |> validate_inclusion(:kind, @kinds)
    |> validate_prefix_length()
    |> assoc_constraint(:organization)
    |> assoc_constraint(:resource)
    |> assoc_constraint(:interface)
    |> assoc_constraint(:source)
    |> unique_constraint([:organization_id, :interface_id, :address, :prefix_length],
      name: :addresses_organization_id_interface_id_address_prefix_length_in
    )
  end

  defp validate_prefix_length(changeset) do
    kind = Ecto.Changeset.get_field(changeset, :kind)

    case kind do
      "ipv4" ->
        validate_number(changeset, :prefix_length,
          greater_than_or_equal_to: 0,
          less_than_or_equal_to: 32
        )

      "ipv6" ->
        validate_number(changeset, :prefix_length,
          greater_than_or_equal_to: 0,
          less_than_or_equal_to: 128
        )

      _ ->
        changeset
    end
  end

  defp trim_address(value) when is_binary(value), do: String.trim(value)
  defp trim_address(value), do: value
end
