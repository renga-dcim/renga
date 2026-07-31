defmodule Renga.Inventory.ChangeEvent do
  @moduledoc """
  Append-only audit record for inventory state transitions.

  Change events are intentionally small and field-oriented so later UI and
  alerting code can explain when resources appeared, changed, conflicted, or
  became stale.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias Renga.Accounts.Organization
  alias Renga.Inventory.Observation
  alias Renga.Inventory.Resource
  alias Renga.Inventory.Source
  alias Renga.Inventory.SyncRun

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @kinds ~w(discovered updated conflict stale manual_override override_removed)
  @timestamps_opts [type: :utc_datetime_usec, autogenerate: {Renga.Time, :utc_now_ms, []}]

  schema "change_events" do
    field :kind, :string
    field :field, :string
    field :old_value, :map
    field :new_value, :map
    field :metadata, :map, default: %{}
    field :occurred_at, :utc_datetime_usec

    belongs_to :organization, Organization
    belongs_to :resource, Resource
    belongs_to :source, Source
    belongs_to :sync_run, SyncRun
    belongs_to :observation, Observation

    timestamps()
  end

  def changeset(change_event, attrs) do
    change_event
    |> cast(attrs, [:kind, :field, :old_value, :new_value, :metadata, :occurred_at])
    |> update_change(:field, &trim_string/1)
    |> validate_required([:organization_id, :kind, :occurred_at])
    |> validate_inclusion(:kind, @kinds)
    |> assoc_constraint(:organization)
    |> assoc_constraint(:resource)
    |> assoc_constraint(:source)
    |> assoc_constraint(:sync_run)
    |> assoc_constraint(:observation)
  end

  defp trim_string(value) when is_binary(value), do: String.trim(value)
  defp trim_string(value), do: value
end
