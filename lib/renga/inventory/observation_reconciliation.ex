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
  @terminal_statuses ~w(succeeded failed)
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
    |> validate_completion_state()
    |> check_constraint(:attempt, name: :observation_reconciliations_attempt_positive)
    |> assoc_constraint(:organization)
    |> assoc_constraint(:observation,
      name: :observation_reconciliations_tenant_observation_fkey
    )
    |> assoc_constraint(:matched_resource,
      name: :observation_reconciliations_tenant_resource_fkey
    )
    |> unique_constraint([:organization_id, :observation_id, :attempt],
      name: :observation_reconciliations_observation_attempt_index
    )
    |> check_constraint(:completed_at,
      name: :observation_reconciliations_completion_state
    )
  end

  defp validate_completion_state(changeset) do
    status = get_field(changeset, :status)
    started_at = get_field(changeset, :started_at)
    completed_at = get_field(changeset, :completed_at)

    cond do
      status in @terminal_statuses and is_nil(completed_at) ->
        add_error(changeset, :completed_at, "is required for a completed reconciliation")

      status in ["pending", "running"] and completed_at ->
        add_error(changeset, :completed_at, "must be empty before reconciliation completes")

      started_at && completed_at && DateTime.compare(completed_at, started_at) == :lt ->
        add_error(changeset, :completed_at, "must not be before started_at")

      true ->
        changeset
    end
  end
end
