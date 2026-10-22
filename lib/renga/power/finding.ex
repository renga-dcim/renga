defmodule Renga.Power.Finding do
  @moduledoc """
  A power finding (RFD 10, "Findings"), opened and resolved by
  `Renga.Power.FindingReconciler` and read through `Renga.Findings` under
  the Power domain:

    * `not_redundant` - a device with more than one power port whose ports
      reach a feed, but not feeds on two sides.
    * `feed_near_capacity` - allocated or measured load over a feed's
      usable capacity or rated current, or a three-phase leg over its
      limit. Allocated and measured load are separate findings
      (`resolution_key`), since either can clear without the other.
    * `supply_failed` - a power supply reporting a failure or no input.
    * `unexpected_draw` - an outlet drawing power with no connection
      recorded.
    * `path_incomplete` - a connected port whose path stops before a feed.
  """

  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec, autogenerate: {Renga.Time, :utc_now_ms, []}]
  @kinds ~w(not_redundant feed_near_capacity supply_failed unexpected_draw path_incomplete)

  schema "power_findings" do
    field :kind, :string
    field :resolution_key, :string, default: ""
    field :status, :string, default: "open"
    field :message, :string
    field :details, :map, default: %{}
    field :last_observed_at, :utc_datetime_usec
    field :resolved_at, :utc_datetime_usec

    belongs_to :organization, Renga.Accounts.Organization
    belongs_to :resource, Renga.Inventory.Resource

    timestamps()
  end

  def kinds, do: @kinds
end
