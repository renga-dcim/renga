defmodule Renga.IPAM.RoutingDomainEvidence do
  @moduledoc """
  One source's claim, in one observation, that an interface is in a routing
  domain (RFD 4, "Observation correlation"): a source-local key and,
  optionally, a route distinguisher.

  Claims are immutable facts. A newer report from the same source about the
  interface makes the older claim stale, whether it names another domain or
  withdraws the claim, so each source has at most one active claim per
  interface. A withdrawal is a row with no key, stored already stale, so a
  late replay of an older claim cannot revive what it withdrew.
  """
  use Ecto.Schema

  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec, autogenerate: {Renga.Time, :utc_now_ms, []}]

  schema "interface_routing_domain_evidence" do
    field :source_local_key, :string
    field :route_distinguisher, :string
    field :metadata, :map, default: %{}
    field :observed_at, :utc_datetime_usec
    field :stale_at, :utc_datetime_usec

    belongs_to :organization, Renga.Accounts.Organization
    belongs_to :interface, Renga.Inventory.Interface
    belongs_to :source, Renga.Inventory.Source
    belongs_to :observation, Renga.Inventory.Observation

    timestamps(updated_at: false)
  end

  def changeset(evidence, attrs) do
    evidence
    |> cast(attrs, [:source_local_key, :route_distinguisher, :metadata, :observed_at, :stale_at])
    |> validate_required([
      :organization_id,
      :interface_id,
      :source_id,
      :observation_id,
      :observed_at
    ])
    |> validate_length(:source_local_key, max: 255)
    |> validate_length(:route_distinguisher, max: 255)
    |> assoc_constraint(:interface,
      name: :interface_routing_domain_evidence_tenant_interface_fkey
    )
    |> assoc_constraint(:source, name: :interface_routing_domain_evidence_tenant_source_fkey)
    |> assoc_constraint(:observation,
      name: :interface_routing_domain_evidence_tenant_observation_fkey
    )
    |> check_constraint(:source_local_key,
      name: :interface_routing_domain_evidence_withdrawal_inactive
    )
    |> unique_constraint([:organization_id, :observation_id, :interface_id],
      name: :interface_routing_domain_evidence_observation_link_index
    )
  end
end
