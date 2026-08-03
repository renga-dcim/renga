defmodule Renga.Inventory.ObservationReconciliation do
  @moduledoc """
  One immutable-in-meaning processing attempt for an observation.

  Attempts may be updated while running, but creating a later attempt preserves
  the outcome and errors from earlier reconciliation code or operator retries.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias Renga.Accounts.Organization
  alias Renga.Inventory.Observation
  alias Renga.Inventory.Resource

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @statuses ~w(pending running succeeded failed)
  @timestamps_opts [type: :utc_datetime_usec, autogenerate: {Renga.Time, :utc_now_ms, []}]

  schema "observation_reconciliations" do
    field :status, :string, default: "pending"
    field :attempt, :integer
    field :errors, :map, default: %{}
    field :metadata, :map, default: %{}
    field :started_at, :utc_datetime_usec
    field :completed_at, :utc_datetime_usec

    belongs_to :organization, Organization
    belongs_to :observation, Observation
    belongs_to :matched_resource, Resource

    timestamps()
  end

  def changeset(reconciliation, attrs) do
    reconciliation
    |> cast(attrs, [:status, :attempt, :errors, :metadata, :started_at, :completed_at])
    |> validate_required([:organization_id, :observation_id, :status, :attempt])
    |> validate_inclusion(:status, @statuses)
    |> validate_number(:attempt, greater_than: 0)
    |> assoc_constraint(:organization)
    |> assoc_constraint(:observation)
    |> assoc_constraint(:matched_resource)
    |> unique_constraint([:organization_id, :observation_id, :attempt],
      name: :observation_reconciliations_observation_attempt_index
    )
  end
end
