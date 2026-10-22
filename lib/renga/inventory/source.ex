defmodule Renga.Inventory.Source do
  @moduledoc """
  A source is an organization-scoped producer of inventory observations.

  Sources are the provenance anchor for host agents, switch collectors, VM
  syncers, and future integrations. Resource facts should point back to the
  source that reported them.

  `authoritative_routing_domains` is the source's routing-domain capability
  (RFD 4, "Observation correlation"): whether its claims about which routing
  domain an interface is in are trusted enough to call a managed assignment
  wrong. Host agents and switch pollers read a device's own configuration,
  so they are authoritative unless an owner or admin says otherwise.

  A collector stream (RFD 11) is a source that one installation's collector
  module reports through: `agent_id` is the installation's agent and
  `collector_id` the stable ID configured locally. The pair is unique and its
  kind never changes, so a retargeted module keeps its history and a queued
  report always replays into the stream that produced it. A host source has
  neither; it is linked from its agent instead.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias Renga.Accounts.Organization
  alias Renga.Inventory.Agent
  alias Renga.Inventory.AddressEvidence
  alias Renga.Inventory.ChangeEvent
  alias Renga.Inventory.InterfaceEvidence
  alias Renga.Inventory.InterfaceRelationshipEvidence
  alias Renga.Inventory.Observation
  alias Renga.Inventory.ResourceIdentifierClaim
  alias Renga.Inventory.SyncRun

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @kinds ~w(host_agent switch_poller vm_provider bmc manual)
  @routing_domain_authorities ~w(host_agent switch_poller)
  @statuses ~w(active revoked disabled)
  @timestamps_opts [type: :utc_datetime_usec, autogenerate: {Renga.Time, :utc_now_ms, []}]

  schema "sources" do
    field :kind, :string
    field :name, :string
    field :status, :string, default: "active"
    field :metadata, :map, default: %{}
    field :authoritative_routing_domains, :boolean, default: false
    field :collector_id, :string

    belongs_to :organization, Organization
    # The installation a collector stream belongs to; `agents` below are the
    # agents that report as this source, which only a host source has.
    belongs_to :installation_agent, Agent, foreign_key: :agent_id
    has_many :agents, Agent
    has_many :address_evidence, AddressEvidence
    has_many :change_events, ChangeEvent
    has_many :interface_evidence, InterfaceEvidence
    has_many :interface_relationship_evidence, InterfaceRelationshipEvidence
    has_many :observations, Observation
    has_many :resource_identifier_claims, ResourceIdentifierClaim
    has_many :sync_runs, SyncRun

    timestamps()
  end

  def changeset(source, attrs) do
    source
    |> cast(attrs, [:kind, :name, :status, :metadata])
    |> validate_required([:organization_id, :kind, :name, :status])
    |> validate_inclusion(:kind, @kinds)
    |> validate_inclusion(:status, @statuses)
    |> assoc_constraint(:organization)
    |> unique_constraint([:organization_id, :name])
    |> unique_constraint([:organization_id, :agent_id, :collector_id],
      name: :sources_agent_collector_index
    )
    |> check_constraint(:collector_id, name: :sources_collector_stream)
    |> validate_stream_kind_unchanged()
    |> put_default_routing_domain_authority()
  end

  # A queued report replays into the stream that produced it, so the stream
  # must still be the kind of collector that wrote it.
  defp validate_stream_kind_unchanged(%{data: %{collector_id: id, kind: kind}} = changeset)
       when is_binary(id) and is_binary(kind) do
    if get_field(changeset, :kind) == kind,
      do: changeset,
      else: add_error(changeset, :kind, "can't change for a collector stream")
  end

  defp validate_stream_kind_unchanged(changeset), do: changeset

  @doc "Whether the source is a collector stream rather than a host or manual source."
  def collector_stream?(%__MODULE__{collector_id: collector_id}), do: not is_nil(collector_id)

  @doc "Sets whether the source's routing-domain claims are authoritative."
  def routing_domain_authority_changeset(source, authoritative?) do
    change(source, authoritative_routing_domains: authoritative?)
  end

  defp put_default_routing_domain_authority(
         %Ecto.Changeset{data: %{__meta__: %{state: :built}}} = changeset
       ) do
    if get_field(changeset, :kind) in @routing_domain_authorities,
      do: put_change(changeset, :authoritative_routing_domains, true),
      else: changeset
  end

  defp put_default_routing_domain_authority(changeset), do: changeset
end
