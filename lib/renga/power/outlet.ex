defmodule Renga.Power.Outlet do
  @moduledoc """
  Where power leaves a device, usually a PDU (RFD 10, "Model"). Created from
  the device's `power_outlet` templates, whose `inlet` attribute names the
  port on the same device that feeds it and whose `feed_leg` (`a`, `b`, or
  `c`) places it on a three-phase leg.
  """

  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec, autogenerate: {Renga.Time, :utc_now_ms, []}]

  schema "power_outlets" do
    field :name, :string
    field :label, :string
    field :connector, :string
    field :feed_leg, :string

    belongs_to :organization, Renga.Accounts.Organization
    belongs_to :resource, Renga.Inventory.Resource
    belongs_to :inlet_port, Renga.Power.Port

    timestamps()
  end
end
