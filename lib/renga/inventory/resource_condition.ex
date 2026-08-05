defmodule Renga.Inventory.ResourceCondition do
  @moduledoc """
  Current independent condition for a canonical resource.

  Conditions prevent lifecycle, inventory freshness, agent reachability, and
  reconciliation progress from being collapsed into one ambiguous status.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias Renga.Accounts.Organization
  alias Renga.Inventory.Resource

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @types ~w(InventoryCurrent AgentConnected Ready Degraded Reconciling)
  @statuses ~w(true false unknown)
  @timestamps_opts [type: :utc_datetime_usec, autogenerate: {Renga.Time, :utc_now_ms, []}]

  schema "resource_conditions" do
    field :type, :string
    field :status, :string
    field :reason, :string
    field :message, :string
    field :observed_generation, :integer
    field :last_transition_at, :utc_datetime_usec
    field :details, :map, default: %{}

    belongs_to :organization, Organization
    belongs_to :resource, Resource

    timestamps()
  end

  def changeset(condition, attrs) do
    condition
    |> cast(attrs, [
      :type,
      :status,
      :reason,
      :message,
      :observed_generation,
      :last_transition_at,
      :details
    ])
    |> validate_required([:organization_id, :resource_id, :type, :status, :last_transition_at])
    |> validate_inclusion(:type, @types)
    |> validate_inclusion(:status, @statuses)
    |> validate_number(:observed_generation, greater_than: 0)
    |> assoc_constraint(:organization)
    |> assoc_constraint(:resource, name: :resource_conditions_organization_resource_fkey)
    |> unique_constraint([:organization_id, :resource_id, :type])
  end
end
