defmodule Renga.Power.PowerFactor do
  @moduledoc """
  The power factor that turns a load's real power in W into apparent power in
  VA (RFD 10, "Capacity and utilization"): VA = W / power factor, with
  0 < power factor <= 1.

  Every value keeps its provenance. A port's own override wins, then its
  hardware type's template, then the organization's default. Headroom that
  rests on the organization default is labelled as such, and with none of
  the three the conversion is unknown: unity is never assumed.
  """

  import Ecto.Changeset

  alias Renga.Power.Port

  @enforce_keys [:value, :source]
  defstruct [:value, :source]

  @type source :: :port | :hardware_type | :organization_default
  @type t :: %__MODULE__{value: Decimal.t(), source: source()}

  @doc "The power factor a port's load converts with, or `nil` when none is known."
  def for_port(%Port{power_factor: %Decimal{} = value}, _default),
    do: %__MODULE__{value: value, source: :port}

  def for_port(%Port{default_power_factor: %Decimal{} = value}, _default),
    do: %__MODULE__{value: value, source: :hardware_type}

  def for_port(%Port{}, %Decimal{} = default),
    do: %__MODULE__{value: default, source: :organization_default}

  def for_port(%Port{}, nil), do: nil

  @doc "Apparent power in VA for `watts` at this power factor."
  def to_va(watts, %__MODULE__{value: value}), do: Decimal.div(Decimal.new(watts), value)

  @doc "Validates a power factor field: above 0, at most 1, three decimal places."
  def validate(changeset, field) do
    changeset = validate_number(changeset, field, greater_than: 0, less_than_or_equal_to: 1)

    # Rounding a value far out of range can exceed Decimal's precision and
    # raise, so places are only checked once the value is in range.
    if Keyword.has_key?(changeset.errors, field) do
      changeset
    else
      validate_change(changeset, field, fn ^field, value ->
        if Decimal.eq?(Decimal.round(value, 3), value),
          do: [],
          else: [{field, "can have at most three decimal places"}]
      end)
    end
  end

  @doc """
  A template attribute's power factor: a JSON number or a plain decimal
  string above 0 and at most 1 with at most three significant decimal
  places, else `nil`. The phase 3 migration's backfill parses the same way.
  """
  # The repo decodes JSON numbers as decimals.
  def parse(%Decimal{} = value), do: parse(Decimal.to_string(value, :normal))
  def parse(value) when is_integer(value) or is_float(value), do: parse(to_string(value))

  def parse(value) when is_binary(value) do
    trimmed = String.trim(value)

    if Regex.match?(~r/^[0-9]{1,16}(\.[0-9]{1,16})?$/, trimmed) do
      decimal = Decimal.new(trimmed)
      rounded = Decimal.round(decimal, 3)

      if Decimal.gt?(decimal, 0) and not Decimal.gt?(decimal, 1) and Decimal.eq?(rounded, decimal),
        do: rounded
    end
  end

  def parse(_value), do: nil

  @doc "How the source reads next to a value."
  def source_label(:port), do: "set here"
  def source_label(:hardware_type), do: "from hardware type"
  def source_label(:organization_default), do: "organization default"
end
