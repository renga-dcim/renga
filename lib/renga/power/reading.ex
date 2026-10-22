defmodule Renga.Power.Reading do
  @moduledoc """
  The current value of one power reading series (RFD 10, "Reading identity
  and eligibility").

  A series is one source's sensor on one target, at one measurement
  boundary, for one quantity over one sampling window length. Its row holds
  the latest sample by event time, whatever order samples arrived in.
  `received_at` is kept for audit only: neither it nor a check-in makes an
  old sample fresh. `fresh_until` is the sample's event time plus the
  freshness window its source mapping declares.

  `validity` is `valid` only for a usable value. A reported missing value, a
  failed read, and evidence the server cannot use (such as a unit that does
  not fit the quantity) are kept as such and never read as zero.
  """

  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @boundaries ~w(host_input supply_input supply_output outlet feed leg)
  @quantities ~w(real_power apparent_power current voltage power_factor state)
  # The unit each numeric quantity is reported in. A state carries none.
  @units %{
    "real_power" => "W",
    "apparent_power" => "VA",
    "current" => "A",
    "voltage" => "V",
    "power_factor" => "1"
  }
  @validities ~w(valid missing failed invalid)
  @origins ~w(native exporter)
  @coverages ~w(complete partial)
  @legs ~w(a b c)
  @component_kinds ~w(power_port power_outlet)

  schema "power_readings" do
    field :target, :string
    field :sensor, :string
    field :boundary, :string
    field :quantity, :string
    field :unit, :string
    field :window_seconds, :integer
    field :leg, :string
    field :component_kind, :string
    field :component_name, :string
    field :coverage, :string
    field :origin, :string
    field :mapping_name, :string
    field :mapping_version, :integer
    field :value, :decimal
    field :state, :string
    field :validity, :string
    field :window_start, :utc_datetime_usec
    field :window_end, :utc_datetime_usec
    field :event_at, :utc_datetime_usec
    field :fresh_until, :utc_datetime_usec
    field :received_at, :utc_datetime_usec

    belongs_to :organization, Renga.Accounts.Organization
    belongs_to :source, Renga.Inventory.Source
  end

  def boundaries, do: @boundaries
  def quantities, do: @quantities
  def units, do: @units
  def validities, do: @validities
  def origins, do: @origins
  def coverages, do: @coverages
  def legs, do: @legs
  def component_kinds, do: @component_kinds

  @doc """
  Whether a reading may count as evidence at `now`: a valid value whose
  freshness window, counted from its event time, has not passed.
  """
  def eligible?(%__MODULE__{validity: "valid", fresh_until: fresh_until}, %DateTime{} = now),
    do: DateTime.compare(fresh_until, now) == :gt

  def eligible?(%__MODULE__{}, %DateTime{}), do: false

  @doc """
  Why a reading is not eligible at `now`, or `nil` when it is: `:stale`
  past its freshness window, otherwise its validity.
  """
  def ineligibility(%__MODULE__{} = reading, %DateTime{} = now) do
    cond do
      reading.validity == "missing" -> :missing
      reading.validity == "failed" -> :failed
      reading.validity == "invalid" -> :invalid
      eligible?(reading, now) -> nil
      true -> :stale
    end
  end
end
