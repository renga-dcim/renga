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
  @case_insensitive_kinds ~w(hostname fqdn machine_id dmi_uuid bmc_address)
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
    |> assoc_constraint(:resource, name: :resource_identifiers_organization_resource_fkey)
    |> unique_constraint([:organization_id, :resource_id, :kind, :normalized_value],
      name: :resource_identifiers_resource_kind_value_index
    )
  end

  @doc """
  Produces the kind-specific comparison form shared by identifiers and claims.

  Network names and hexadecimal machine identifiers are case-insensitive, MAC
  addresses also have a canonical delimiter form, and opaque provider or
  vendor values retain their case.
  """
  def normalize_value("mac_address", value) when is_binary(value) do
    trimmed_value = String.trim(value)

    compact_value =
      trimmed_value
      |> String.downcase()
      |> String.replace(~r/[:.\-]/, "")

    if Regex.match?(~r/\A[0-9a-f]{12}\z/, compact_value) do
      compact_value
      |> String.graphemes()
      |> Enum.chunk_every(2)
      |> Enum.map_join(":", &Enum.join/1)
    else
      String.downcase(trimmed_value)
    end
  end

  def normalize_value(kind, value)
      when kind in @case_insensitive_kinds and is_binary(value) do
    value
    |> String.trim()
    |> String.downcase()
  end

  def normalize_value(_kind, value) when is_binary(value), do: String.trim(value)
  def normalize_value(_kind, value), do: value

  defp put_normalized_value(changeset) do
    case {get_field(changeset, :kind), get_field(changeset, :value)} do
      {kind, value} when is_binary(kind) and is_binary(value) ->
        put_change(changeset, :normalized_value, normalize_value(kind, value))

      _kind_and_value ->
        changeset
    end
  end
end
