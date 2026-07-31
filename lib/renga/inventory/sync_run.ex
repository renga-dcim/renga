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
  @timestamps_opts [type: :utc_datetime]

  schema "sync_runs" do
    field :status, :string, default: "running"
    field :started_at, :utc_datetime
    field :completed_at, :utc_datetime
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
    |> assoc_constraint(:organization)
    |> assoc_constraint(:source)
  end
end
