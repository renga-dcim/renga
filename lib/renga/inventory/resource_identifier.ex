defmodule Renga.Inventory.ResourceIdentifier do
  @moduledoc """
  Source-neutral canonical identifier attached to one resource.

  Canonical identifiers are deliberately not unique across an organization.
  Duplicate serials and machine IDs must remain representable so reconciliation
  can surface conflicts instead of rejecting evidence at the database boundary.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias Renga.Accounts.Organization
  alias Renga.Inventory.Resource
  alias Renga.Inventory.ResourceIdentifierClaim

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @kinds ~w(serial_number asset_tag hostname fqdn machine_id dmi_uuid mac_address provider_instance_id bmc_address external_id)
  @timestamps_opts [type: :utc_datetime_usec, autogenerate: {Renga.Time, :utc_now_ms, []}]

  schema "resource_identifiers" do
    field :kind, :string
    field :value, :string
    field :normalized_value, :string
    field :metadata, :map, default: %{}

    belongs_to :organization, Organization
    belongs_to :resource, Resource
    has_many :claims, ResourceIdentifierClaim

    timestamps()
  end

  def changeset(identifier, attrs) do
    identifier
    |> cast(attrs, [:kind, :value, :metadata])
    |> update_change(:value, &String.trim/1)
    |> put_normalized_value()
    |> validate_required([:organization_id, :resource_id, :kind, :value, :normalized_value])
    |> validate_inclusion(:kind, @kinds)
    |> assoc_constraint(:organization)
    |> assoc_constraint(:resource)
    |> unique_constraint([:organization_id, :resource_id, :kind, :normalized_value],
      name: :resource_identifiers_resource_kind_value_index
    )
  end

  @doc """
  Produces the comparison form shared by canonical identifiers and claims.
  """
  def normalize_value(value) when is_binary(value) do
    value
    |> String.trim()
    |> String.downcase()
  end

  def normalize_value(value), do: value

  defp put_normalized_value(changeset) do
    case get_field(changeset, :value) do
      value when is_binary(value) ->
        put_change(changeset, :normalized_value, normalize_value(value))

      _value ->
        changeset
    end
  end
end
