defmodule Renga.Inventory.ResourceIdentifier do
  @moduledoc """
  Observed identity fact used to match observations to canonical resources.

  Identifiers keep source, confidence, and first/last seen timestamps separate
  from canonical resource fields because hostnames, MACs, and provider ids can
  move or conflict over time.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias Renga.Accounts.Organization
  alias Renga.Inventory.Resource
  alias Renga.Inventory.Source

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @kinds ~w(hostname fqdn machine_id dmi_uuid serial_number mac_address provider_instance_id bmc_address)
  @timestamps_opts [type: :utc_datetime]

  schema "resource_identifiers" do
    field :kind, :string
    field :value, :string
    field :confidence, :integer, default: 100
    field :first_seen_at, :utc_datetime
    field :last_seen_at, :utc_datetime
    field :metadata, :map, default: %{}

    belongs_to :organization, Organization
    belongs_to :resource, Resource
    belongs_to :source, Source

    timestamps()
  end

  def changeset(identifier, attrs) do
    identifier
    |> cast(attrs, [
      :kind,
      :value,
      :confidence,
      :first_seen_at,
      :last_seen_at,
      :metadata
    ])
    |> update_change(:value, &trim_identifier_value/1)
    |> validate_required([:organization_id, :resource_id, :kind, :value, :confidence])
    |> validate_inclusion(:kind, @kinds)
    |> validate_number(:confidence, greater_than_or_equal_to: 0, less_than_or_equal_to: 100)
    |> assoc_constraint(:organization)
    |> assoc_constraint(:resource)
    |> assoc_constraint(:source)
    |> unique_constraint([:organization_id, :source_id, :kind, :value])
    |> unique_constraint([:organization_id, :resource_id, :kind, :value],
      name: :resource_identifiers_resource_kind_value_index
    )
  end

  defp trim_identifier_value(value) when is_binary(value), do: String.trim(value)
  defp trim_identifier_value(value), do: value
end
