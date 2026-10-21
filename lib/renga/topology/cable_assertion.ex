defmodule Renga.Topology.CableAssertion do
  @moduledoc """
  Append-only, attributed claim about current direct cabling.

  Operator and trusted-import assertions are confirmed and drive the reconciled
  cable projection. Neighbor-evidence assertions are proposals: they are
  attributed to the evidence that produced them and can never create, delete,
  or move a current cable on their own.

  Facts are immutable and rows are retained: database triggers reject updates and
  reject deletes while the organization exists, so attribution cannot be
  rewritten and history cannot be cascaded away by a deleted source or endpoint.
  Deleting an endpoint or importing source that still carries claims is
  therefore rejected: retire the cabling with `Renga.Topology.retract_cable/2`
  first, which records the removal. `sequence` breaks ties between claims that
  share a millisecond `asserted_at`.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias Renga.Topology.CableAttributes

  @kinds ~w(operator import neighbor_evidence)
  @actions ~w(assert retract)
  @confirmations ~w(confirmed proposed)

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [
    type: :utc_datetime_usec,
    autogenerate: {Renga.Time, :utc_now_ms, []},
    updated_at: false
  ]

  schema "cable_assertions" do
    field :cable_kind, :string, default: "data"
    field :sequence, :integer, read_after_writes: true
    field :kind, :string
    field :action, :string
    field :confirmation, :string
    field :actor_user_id, :binary_id
    field :asserted_at, :utc_datetime_usec
    field :cable_type, :string
    field :status, :string
    field :label, :string
    field :color, :string
    field :length_value, :decimal
    field :length_unit, :string
    field :description, :string
    field :metadata, :map, default: %{}
    belongs_to :organization, Renga.Accounts.Organization
    belongs_to :interface_a, Renga.Inventory.Interface
    belongs_to :interface_b, Renga.Inventory.Interface
    # RFD 10: a power cable joins a power port to an outlet or a feed.
    belongs_to :power_port, Renga.Power.Port
    belongs_to :power_outlet, Renga.Power.Outlet
    belongs_to :power_feed, Renga.Power.Feed
    belongs_to :source, Renga.Inventory.Source
    belongs_to :interface_neighbor_evidence, Renga.Topology.InterfaceNeighborEvidence
    timestamps()
  end

  def changeset(assertion, attrs) do
    assertion
    |> CableAttributes.cast_attributes(attrs)
    |> cast(attrs, [:interface_a_id, :interface_b_id, :kind, :action, :confirmation, :asserted_at])
    |> validate_required([
      :organization_id,
      :interface_a_id,
      :interface_b_id,
      :kind,
      :action,
      :confirmation,
      :asserted_at,
      :metadata
    ])
    |> validate_inclusion(:kind, @kinds)
    |> validate_inclusion(:action, @actions)
    |> validate_inclusion(:confirmation, @confirmations)
    |> check_constraint(:interface_b_id,
      name: :cable_assertions_canonical_order,
      message: "must be ordered after the first endpoint"
    )
    |> check_constraint(:kind, name: :cable_assertions_valid_kind)
    |> check_constraint(:action, name: :cable_assertions_valid_action)
    |> check_constraint(:confirmation, name: :cable_assertions_valid_confirmation)
    |> check_constraint(:confirmation, name: :cable_assertions_confirmation_shape)
    |> check_constraint(:metadata, name: :cable_assertions_retract_shape)
    |> check_constraint(:status, name: :cable_assertions_valid_status)
    |> check_constraint(:length_unit, name: :cable_assertions_valid_length_unit)
    |> check_constraint(:length_value, name: :cable_assertions_length_pair)
    |> check_constraint(:length_value, name: :cable_assertions_positive_length)
    |> check_constraint(:color, name: :cable_assertions_color_format)
    |> assoc_constraint(:interface_a, name: :cable_assertions_tenant_a_fkey)
    |> assoc_constraint(:interface_b, name: :cable_assertions_tenant_b_fkey)
    |> assoc_constraint(:source, name: :cable_assertions_tenant_source_fkey)
    |> assoc_constraint(:interface_neighbor_evidence,
      name: :cable_assertions_tenant_evidence_fkey
    )
    |> check_constraint(:base,
      name: :cable_assertions_attribution_shape,
      message: "does not match the assertion kind"
    )
  end

  @doc """
  An operator's or import's claim about a power cable (RFD 10): a power port
  to an outlet or a feed. Evidence never proposes power cables.
  """
  def power_changeset(assertion, attrs) do
    assertion
    |> CableAttributes.cast_attributes(attrs)
    |> cast(attrs, [
      :power_port_id,
      :power_outlet_id,
      :power_feed_id,
      :kind,
      :action,
      :confirmation,
      :asserted_at
    ])
    |> put_change(:cable_kind, "power")
    |> validate_required([
      :organization_id,
      :power_port_id,
      :kind,
      :action,
      :confirmation,
      :asserted_at,
      :metadata
    ])
    |> validate_inclusion(:kind, ~w(operator import))
    |> validate_inclusion(:action, @actions)
    |> validate_inclusion(:confirmation, @confirmations)
    |> check_constraint(:power_port_id, name: :cable_assertions_endpoint_shape)
    |> check_constraint(:confirmation, name: :cable_assertions_confirmation_shape)
    |> check_constraint(:metadata, name: :cable_assertions_retract_shape)
    |> check_constraint(:status, name: :cable_assertions_valid_status)
    |> check_constraint(:length_unit, name: :cable_assertions_valid_length_unit)
    |> check_constraint(:length_value, name: :cable_assertions_length_pair)
    |> check_constraint(:length_value, name: :cable_assertions_positive_length)
    |> check_constraint(:color, name: :cable_assertions_color_format)
    |> assoc_constraint(:power_port, name: :cable_assertions_tenant_power_port_fkey)
    |> assoc_constraint(:power_outlet, name: :cable_assertions_tenant_power_outlet_fkey)
    |> assoc_constraint(:power_feed, name: :cable_assertions_tenant_power_feed_fkey)
    |> assoc_constraint(:source, name: :cable_assertions_tenant_source_fkey)
    |> check_constraint(:base,
      name: :cable_assertions_attribution_shape,
      message: "does not match the assertion kind"
    )
  end
end
