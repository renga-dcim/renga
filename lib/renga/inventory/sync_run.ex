defmodule Renga.Inventory.SyncRun do
  @moduledoc """
  Tracks one inventory ingest attempt from a source.

  Sync runs give observations and change events a batch-level anchor so the
  system can report whether a collector succeeded, partially failed, or left
  resources stale after a missed refresh.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias Renga.Accounts.Organization
  alias Renga.Inventory.ChangeEvent
  alias Renga.Inventory.Observation
  alias Renga.Inventory.Source

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @statuses ~w(running succeeded failed partial)
  @terminal_statuses ~w(succeeded failed partial)
  @timestamps_opts [type: :utc_datetime_usec, autogenerate: {Renga.Time, :utc_now_ms, []}]

  schema "sync_runs" do
    field :status, :string, default: "running"
    field :started_at, :utc_datetime_usec
    field :completed_at, :utc_datetime_usec
    field :resource_count, :integer, default: 0
    field :error_count, :integer, default: 0
    field :metadata, :map, default: %{}

    belongs_to :organization, Organization
    belongs_to :source, Source
    has_many :observations, Observation
    has_many :change_events, ChangeEvent

    timestamps()
  end

  def changeset(sync_run, attrs) do
    sync_run
    |> cast(attrs, [:status, :started_at, :completed_at, :resource_count, :error_count, :metadata])
    |> validate_required([:organization_id, :status, :started_at, :resource_count, :error_count])
    |> validate_inclusion(:status, @statuses)
    |> validate_number(:resource_count, greater_than_or_equal_to: 0)
    |> validate_number(:error_count, greater_than_or_equal_to: 0)
    |> validate_completion_state()
    |> assoc_constraint(:organization)
    |> assoc_constraint(:source)
    |> check_constraint(:completed_at, name: :sync_runs_completion_state)
  end

  defp validate_completion_state(changeset) do
    status = get_field(changeset, :status)
    started_at = get_field(changeset, :started_at)
    completed_at = get_field(changeset, :completed_at)

    cond do
      status in @terminal_statuses and is_nil(completed_at) ->
        add_error(changeset, :completed_at, "is required for a completed run")

      status == "running" and completed_at ->
        add_error(changeset, :completed_at, "must be empty while the run is running")

      started_at && completed_at && DateTime.compare(completed_at, started_at) == :lt ->
        add_error(changeset, :completed_at, "must not be before started_at")

      true ->
        changeset
    end
  end
end
