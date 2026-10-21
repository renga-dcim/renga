defmodule Renga.Inventory.CollectorTargetResource do
  @moduledoc """
  A resource a collector target reported (RFD 11, "Observation payload").

  Present while `withdrawn_at` is unset or older than `last_reported_at`. Only
  a complete report that reached the target withdraws a resource it no longer
  contains; partial, failed, and unreachable reports leave it alone, and an
  older report replayed late cannot bring it back.
  """

  use Ecto.Schema

  alias Renga.Accounts.Organization
  alias Renga.Inventory.CollectorTarget
  alias Renga.Inventory.Resource
  alias Renga.Inventory.Source

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec, autogenerate: {Renga.Time, :utc_now_ms, []}]

  schema "collector_target_resources" do
    field :first_reported_at, :utc_datetime_usec
    field :last_reported_at, :utc_datetime_usec
    field :withdrawn_at, :utc_datetime_usec

    belongs_to :organization, Organization
    belongs_to :source, Source
    belongs_to :target, CollectorTarget
    belongs_to :resource, Resource

    timestamps()
  end

  @doc "Whether the target still reports the resource."
  def present?(%__MODULE__{withdrawn_at: nil}), do: true

  def present?(%__MODULE__{withdrawn_at: withdrawn_at, last_reported_at: last_reported_at}),
    do: DateTime.compare(last_reported_at, withdrawn_at) == :gt
end
