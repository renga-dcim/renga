defmodule Renga.Inventory.CollectorTarget do
  @moduledoc """
  One target a collector stream reports on: a switch poller's target address
  or a libvirt stream's hypervisor (RFD 11).

  Freshness belongs to the target, not the installation: `last_reachable_at`
  moves only when a report reached the target, so host check-ins and host
  reports never make a silent switch look current. An unreachable target's
  facts are unknown, so its resources stay as they were.
  """

  use Ecto.Schema

  alias Renga.Accounts.Organization
  alias Renga.Inventory.CollectorTargetResource
  alias Renga.Inventory.Observation
  alias Renga.Inventory.Source

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec, autogenerate: {Renga.Time, :utc_now_ms, []}]

  schema "collector_targets" do
    field :key, :string
    field :status, :string
    field :error, :string
    field :last_reported_at, :utc_datetime_usec
    field :last_reachable_at, :utc_datetime_usec

    belongs_to :organization, Organization
    belongs_to :source, Source
    belongs_to :last_observation, Observation
    has_many :resources, CollectorTargetResource, foreign_key: :target_id

    timestamps()
  end
end
