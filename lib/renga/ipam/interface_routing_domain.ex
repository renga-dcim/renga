defmodule Renga.IPAM.InterfaceRoutingDomain do
  @moduledoc """
  The resolved current routing domain of one interface (RFD 4, "Observation
  correlation"), rebuilt from active claims by `Renga.IPAM.RoutingDomains`.

  `resolution` says how the claim's key reached a namespace: an explicit
  `mapping`, a `route_distinguisher` or VRF `name` match, the reserved
  `default` key for the global table, or `unmapped` when nothing matches.
  `vrf_id` is nil for the global table and for an unmapped claim. An
  interface with no row has no claim and is in the global table.
  """
  use Ecto.Schema

  @primary_key {:interface_id, :binary_id, autogenerate: false}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec, autogenerate: {Renga.Time, :utc_now_ms, []}]

  @resolutions ~w(mapping route_distinguisher name default unmapped)

  schema "interface_routing_domains" do
    field :source_id, :binary_id
    field :source_local_key, :string
    field :route_distinguisher, :string
    field :authoritative, :boolean
    field :resolution, :string
    field :observed_at, :utc_datetime_usec

    belongs_to :organization, Renga.Accounts.Organization
    belongs_to :evidence, Renga.IPAM.RoutingDomainEvidence
    belongs_to :vrf, Renga.IPAM.Vrf

    timestamps()
  end

  def resolutions, do: @resolutions

  @doc "True when the claim resolved to a namespace, the global table included."
  def mapped?(%__MODULE__{resolution: resolution}), do: resolution != "unmapped"
end
