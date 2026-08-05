defmodule Renga.Inventory.AddressEvidence do
  @moduledoc """
  Observation-scoped source evidence for a canonical assigned address.

  Both evidence and canonical state use PostgreSQL `inet`, preserving address
  family and prefix length through reconciliation.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias Renga.Accounts.Organization
  alias Renga.Inventory.Address
  alias Renga.Inventory.Observation
  alias Renga.Inventory.Source
  alias Renga.Types.Inet

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec, autogenerate: {Renga.Time, :utc_now_ms, []}]

  schema "address_evidence" do
    field :address, Inet
    field :scope, :string
    field :metadata, :map, default: %{}
    field :observed_at, :utc_datetime_usec

    belongs_to :organization, Organization
    belongs_to :address_record, Address, foreign_key: :address_id
    belongs_to :source, Source
    belongs_to :observation, Observation

    timestamps()
  end

  def changeset(evidence, attrs) do
    evidence
    |> cast(attrs, [:address, :scope, :metadata, :observed_at])
    |> validate_required([
      :organization_id,
      :address_id,
      :source_id,
      :observation_id,
      :address,
      :observed_at
    ])
    |> assoc_constraint(:organization)
    |> assoc_constraint(:address_record, name: :address_evidence_tenant_address_fkey)
    |> assoc_constraint(:source, name: :address_evidence_tenant_source_fkey)
    |> assoc_constraint(:observation, name: :address_evidence_tenant_observation_fkey)
    |> unique_constraint([:organization_id, :observation_id, :address_id],
      name: :address_evidence_observation_link_index
    )
  end
end
