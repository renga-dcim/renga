defmodule Renga.Inventory.Source do
  @moduledoc """
  A source is an organization-scoped producer of inventory observations.

  Sources are the provenance anchor for host agents, switch collectors, VM
  syncers, and future integrations. Resource facts should point back to the
  source that reported them.
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
  @statuses ~w(active revoked disabled)
  @timestamps_opts [type: :utc_datetime_usec, autogenerate: {Renga.Time, :utc_now_ms, []}]

  schema "sources" do
    field :kind, :string
    field :name, :string
    field :status, :string, default: "active"
    field :metadata, :map, default: %{}

    belongs_to :organization, Organization
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
  end
end
