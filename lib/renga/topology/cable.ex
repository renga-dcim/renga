defmodule Renga.Topology.Cable do
  @moduledoc """
  Reconciled current direct cable selected from confirmed assertions.

  Endpoints are canonical and immutable, and the database enforces at most one
  current cable per endpoint. Only this projection occupies an endpoint; plans
  and proposals never do.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias Renga.Topology.CableAttributes

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec, autogenerate: {Renga.Time, :utc_now_ms, []}]

  schema "cables" do
    field :cable_type, :string
    field :status, :string, default: "connected"
    field :label, :string
    field :color, :string
    field :length_value, :decimal
    field :length_unit, :string
    field :description, :string
    field :metadata, :map, default: %{}
    field :last_asserted_at, :utc_datetime_usec
    belongs_to :organization, Renga.Accounts.Organization
    belongs_to :interface_a, Renga.Inventory.Interface
    belongs_to :interface_b, Renga.Inventory.Interface
    belongs_to :primary_assertion, Renga.Topology.CableAssertion
    timestamps()
  end

  def changeset(cable, attrs) do
    cable
    |> CableAttributes.cast_attributes(attrs)
    |> validate_required([
      :organization_id,
      :interface_a_id,
      :interface_b_id,
      :primary_assertion_id,
      :status,
      :metadata,
      :last_asserted_at
    ])
    |> check_constraint(:interface_b_id,
      name: :cables_canonical_order,
      message: "must be ordered after the first endpoint"
    )
    |> check_constraint(:status, name: :cables_valid_status)
    |> check_constraint(:length_unit, name: :cables_valid_length_unit)
    |> check_constraint(:length_value, name: :cables_length_pair)
    |> check_constraint(:length_value, name: :cables_positive_length)
    |> check_constraint(:color, name: :cables_color_format)
    |> assoc_constraint(:interface_a, name: :cables_tenant_a_fkey)
    |> assoc_constraint(:interface_b, name: :cables_tenant_b_fkey)
    |> assoc_constraint(:primary_assertion, name: :cables_tenant_assertion_fkey)
    |> unique_constraint([:organization_id, :interface_a_id, :interface_b_id],
      name: :cables_endpoints_index
    )
  end
end
