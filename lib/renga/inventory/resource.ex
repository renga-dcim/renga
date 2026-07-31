defmodule Renga.Inventory.Resource do
  @moduledoc """
  Canonical current inventory record for something Renga knows about.

  Resource fields are the current view used for UI and queries. Observed
  matching evidence belongs in `ResourceIdentifier` so reconciliation can
  improve without losing provenance.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias Renga.Accounts.Organization
  alias Renga.Inventory.Address
  alias Renga.Inventory.ChangeEvent
  alias Renga.Inventory.Interface
  alias Renga.Inventory.Observation
  alias Renga.Inventory.ResourceIdentifier
  alias Renga.Inventory.ResourceOverride

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @kinds ~w(server switch vm container pdu storage unknown)
  @statuses ~w(active inactive stale retired unknown)
  @timestamps_opts [type: :utc_datetime_usec, autogenerate: {Renga.Time, :utc_now_ms, []}]

  schema "resources" do
    field :kind, :string
    field :external_id, :string
    field :serial_number, :string
    field :asset_tag, :string
    field :hostname, :string
    field :fqdn, :string
    field :vendor, :string
    field :model, :string
    field :status, :string, default: "unknown"
    field :metadata, :map, default: %{}
    field :first_seen_at, :utc_datetime_usec
    field :last_seen_at, :utc_datetime_usec
    field :last_changed_at, :utc_datetime_usec
    field :stale_at, :utc_datetime_usec

    belongs_to :organization, Organization
    has_many :addresses, Address
    has_many :change_events, ChangeEvent
    has_many :identifiers, ResourceIdentifier
    has_many :interfaces, Interface
    has_many :observations, Observation
    has_many :overrides, ResourceOverride

    timestamps()
  end

  def changeset(resource, attrs) do
    resource
    |> cast(attrs, [
      :kind,
      :external_id,
      :serial_number,
      :asset_tag,
      :hostname,
      :fqdn,
      :vendor,
      :model,
      :status,
      :metadata,
      :first_seen_at,
      :last_seen_at,
      :last_changed_at,
      :stale_at
    ])
    |> validate_required([:organization_id, :kind, :status])
    |> validate_inclusion(:kind, @kinds)
    |> validate_inclusion(:status, @statuses)
    |> assoc_constraint(:organization)
    |> unique_constraint([:organization_id, :external_id])
    |> unique_constraint([:organization_id, :serial_number])
    |> unique_constraint([:organization_id, :asset_tag])
  end
end
