defmodule Renga.Power.Port do
  @moduledoc """
  Where power enters a device (RFD 10, "Model"): a server's power supply or
  a PDU's inlet. Created from the device's `power_port` templates.

  `default_allocated_draw_w` comes from the template's `allocated_draw_w`
  attribute and `allocated_draw_w` is an operator's override; the port's
  allocation is the override when set. All draws are real power in W.

  `default_power_factor` comes from the template's `power_factor` attribute
  and `power_factor` is an operator's override, both configured values
  between 0 and 1 that turn the port's watts into volt-amperes (RFD 10
  phase 3). See `Renga.Power.PowerFactor` for the organization default.
  """

  use Ecto.Schema

  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec, autogenerate: {Renga.Time, :utc_now_ms, []}]
  @max_watts 999_999_999

  schema "power_ports" do
    field :name, :string
    field :label, :string
    field :connector, :string
    # Set while cable history keeps an endpoint the hardware type dropped.
    field :retired_at, :utc_datetime_usec
    field :maximum_draw_w, :integer
    field :default_allocated_draw_w, :integer
    field :allocated_draw_w, :integer
    field :default_power_factor, :decimal
    field :power_factor, :decimal

    belongs_to :organization, Renga.Accounts.Organization
    belongs_to :resource, Renga.Inventory.Resource

    timestamps()
  end

  @doc "The watts allocated to the port: the override, else the template's default."
  def allocated_draw_w(%__MODULE__{allocated_draw_w: nil, default_allocated_draw_w: default}),
    do: default

  def allocated_draw_w(%__MODULE__{allocated_draw_w: watts}), do: watts

  @doc "An operator's change: the allocated draw and power factor overrides."
  def allocation_changeset(port, attrs) do
    port
    |> cast(attrs, [:allocated_draw_w, :power_factor])
    |> validate_number(:allocated_draw_w, greater_than: 0, less_than_or_equal_to: @max_watts)
    |> Renga.Power.PowerFactor.validate(:power_factor)
    |> check_constraint(:allocated_draw_w, name: :power_ports_draws)
    |> check_constraint(:power_factor, name: :power_ports_power_factors)
  end
end
