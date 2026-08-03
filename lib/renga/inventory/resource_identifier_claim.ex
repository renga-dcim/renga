defmodule Renga.Inventory.ResourceIdentifierClaim do
  @moduledoc """
  One source assertion about resource identity from an immutable observation.

  Claims can remain unmatched, point at a resource, or confirm a canonical
  identifier. Keeping every observation-scoped assertion permits multi-source
  agreement and conflicting values to coexist for later reconciliation.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias Renga.Accounts.Organization
  alias Renga.Inventory.Observation
  alias Renga.Inventory.Resource
  alias Renga.Inventory.ResourceIdentifier
  alias Renga.Inventory.Source

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @kinds ~w(serial_number asset_tag hostname fqdn machine_id dmi_uuid mac_address provider_instance_id bmc_address external_id)
  @timestamps_opts [type: :utc_datetime_usec, autogenerate: {Renga.Time, :utc_now_ms, []}]

  schema "resource_identifier_claims" do
    field :kind, :string
    field :value, :string
    field :normalized_value, :string
    field :confidence, :integer, default: 100
    field :first_seen_at, :utc_datetime_usec
    field :last_seen_at, :utc_datetime_usec
    field :metadata, :map, default: %{}

    belongs_to :organization, Organization
    belongs_to :resource_identifier, ResourceIdentifier
    belongs_to :resource, Resource
    belongs_to :source, Source
    belongs_to :observation, Observation

    timestamps()
  end

  def changeset(claim, attrs) do
    claim
    |> cast(attrs, [:kind, :value, :confidence, :first_seen_at, :last_seen_at, :metadata])
    |> update_change(:value, &String.trim/1)
    |> put_normalized_value()
    |> validate_required([
      :organization_id,
      :source_id,
      :observation_id,
      :kind,
      :value,
      :normalized_value,
      :confidence,
      :first_seen_at,
      :last_seen_at
    ])
    |> validate_inclusion(:kind, @kinds)
    |> validate_number(:confidence, greater_than_or_equal_to: 0, less_than_or_equal_to: 100)
    |> assoc_constraint(:organization)
    |> assoc_constraint(:resource_identifier)
    |> assoc_constraint(:resource)
    |> assoc_constraint(:source)
    |> assoc_constraint(:observation)
    |> unique_constraint([:organization_id, :observation_id, :kind, :normalized_value],
      name: :resource_identifier_claims_observation_value_index
    )
  end

  defp put_normalized_value(changeset) do
    case get_field(changeset, :value) do
      value when is_binary(value) ->
        put_change(changeset, :normalized_value, ResourceIdentifier.normalize_value(value))

      _value ->
        changeset
    end
  end
end
