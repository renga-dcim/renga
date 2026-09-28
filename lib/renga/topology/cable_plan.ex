defmodule Renga.Topology.CablePlan do
  @moduledoc """
  Desired direct cable connectivity between two canonical interfaces.

  A plan is intent only. It never reserves an endpoint and never replaces the
  reconciled cable, so it can disagree with current cabling and produce a
  feasibility or drift finding.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias Renga.Topology.CableAttributes

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec, autogenerate: {Renga.Time, :utc_now_ms, []}]

  schema "cable_plans" do
    field :cable_type, :string
    field :status, :string, default: "planned"
    field :label, :string
    field :color, :string
    field :length_value, :decimal
    field :length_unit, :string
    field :description, :string
    field :metadata, :map, default: %{}
    belongs_to :organization, Renga.Accounts.Organization
    belongs_to :interface_a, Renga.Inventory.Interface
    belongs_to :interface_b, Renga.Inventory.Interface
    timestamps()
  end

  def changeset(plan, attrs) do
    plan
    |> CableAttributes.cast_attributes(attrs)
    |> validate_required([
      :organization_id,
      :interface_a_id,
      :interface_b_id,
      :status,
      :metadata
    ])
    |> check_constraint(:interface_b_id,
      name: :cable_plans_canonical_order,
      message: "must be ordered after the first endpoint"
    )
    |> check_constraint(:status, name: :cable_plans_valid_status)
    |> check_constraint(:length_unit, name: :cable_plans_valid_length_unit)
    |> check_constraint(:length_value, name: :cable_plans_length_pair)
    |> check_constraint(:length_value, name: :cable_plans_positive_length)
    |> check_constraint(:color, name: :cable_plans_color_format)
    |> assoc_constraint(:interface_a, name: :cable_plans_tenant_a_fkey)
    |> assoc_constraint(:interface_b, name: :cable_plans_tenant_b_fkey)
    |> unique_constraint([:organization_id, :interface_a_id, :interface_b_id],
      name: :cable_plans_endpoints_index
    )
  end
end
