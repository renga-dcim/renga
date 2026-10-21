defmodule Renga.Power.Capacity do
  @moduledoc """
  Usable capacity of a power feed, in the unit its supply is measured in
  (RFD 10, "Capacity and utilization").

  AC capacity is apparent power in VA: voltage × amperage for single-phase,
  or √3 × line-to-line voltage × line current for balanced three-phase. DC
  capacity is real power in W: voltage × amperage. Usable capacity applies
  the feed's maximum utilization to the rated figure.

  Units are kept with every value. VA and W are never compared or summed
  with each other, and neither is current in A; turning watts into
  volt-amperes needs a power factor, which phase 3 adds.
  """

  alias Renga.Power.Feed

  @enforce_keys [:rated, :usable, :unit]
  defstruct [:rated, :usable, :unit]

  @type t :: %__MODULE__{rated: Decimal.t(), usable: Decimal.t(), unit: :va | :w}

  @sqrt3 Decimal.new("1.7320508075688772935274463415")

  @doc "The feed's rated and usable capacity."
  def of(%Feed{} = feed) do
    rated = rated(feed)

    usable =
      rated
      |> Decimal.mult(feed.max_utilization)
      |> Decimal.div(100)

    %__MODULE__{rated: rated, usable: usable, unit: unit(feed)}
  end

  @doc "The unit a feed's capacity is in: VA for AC, W for DC."
  def unit(%Feed{supply: "ac"}), do: :va
  def unit(%Feed{supply: "dc"}), do: :w

  defp rated(%Feed{supply: "ac", phase: "three", voltage: voltage, amperage: amperage}),
    do: @sqrt3 |> Decimal.mult(voltage) |> Decimal.mult(amperage)

  defp rated(%Feed{voltage: voltage, amperage: amperage}), do: Decimal.mult(voltage, amperage)

  @doc """
  Formats a capacity value for display, rounded down to a whole unit so a
  rounded figure never overstates what is usable.
  """
  def format(%Decimal{} = value, unit) do
    whole = value |> Decimal.round(0, :floor) |> Decimal.to_integer()
    "#{group_thousands(whole)} #{unit_label(unit)}"
  end

  def unit_label(:va), do: "VA"
  def unit_label(:w), do: "W"

  defp group_thousands(integer) do
    integer
    |> Integer.to_string()
    |> String.reverse()
    |> String.replace(~r/(\d{3})(?=\d)/, "\\1,")
    |> String.reverse()
  end
end
