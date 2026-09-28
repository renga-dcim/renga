defmodule Renga.Topology.CableAttributes do
  @moduledoc false

  # Cable plans, attributed assertions, and reconciled cables describe the same
  # physical medium, so their attribute vocabulary and validation live here
  # instead of drifting across three schemas.

  import Ecto.Changeset

  @fields [
    :cable_type,
    :status,
    :label,
    :color,
    :length_value,
    :length_unit,
    :description,
    :metadata
  ]

  @statuses ~w(planned connected decommissioning)
  @length_units ~w(m cm ft in)
  @color_format ~r/\A#[0-9a-fA-F]{6}\z/
  # The column is numeric(12,3): PostgreSQL rounds to the declared scale before
  # checking precision, so anything above this could round up to 1000000000.000
  # and overflow.
  @max_length Decimal.new("999999999.999")

  def fields, do: @fields

  def cast_attributes(changeset, attrs) do
    changeset
    |> cast(attrs, @fields)
    |> update_change(:cable_type, &trim_optional/1)
    |> update_change(:label, &trim_optional/1)
    |> update_change(:length_unit, &trim_optional/1)
    |> update_change(:description, &trim_optional/1)
    |> update_change(:color, &normalize_color/1)
    |> validate_length(:cable_type, max: 255, count: :codepoints)
    |> validate_length(:label, max: 255, count: :codepoints)
    |> validate_inclusion(:status, @statuses)
    |> validate_inclusion(:length_unit, @length_units)
    |> validate_format(:color, @color_format)
    |> validate_number(:length_value,
      greater_than: 0,
      less_than_or_equal_to: @max_length
    )
    |> validate_length_pair()
  end

  @doc "Compares persisted and reported values without numeric scale noise."
  def same_value?(%Decimal{} = left, %Decimal{} = right), do: Decimal.equal?(left, right)
  def same_value?(left, right), do: left == right

  defp validate_length_pair(changeset) do
    value = get_field(changeset, :length_value)
    unit = get_field(changeset, :length_unit)

    if is_nil(value) == is_nil(unit) do
      changeset
    else
      add_error(changeset, :length_value, "must be reported with a length unit")
    end
  end

  defp normalize_color(nil), do: nil

  defp normalize_color(color) when is_binary(color) do
    case String.trim(color) do
      "" -> nil
      color -> String.downcase(color)
    end
  end

  defp normalize_color(color), do: color

  defp trim_optional(nil), do: nil

  defp trim_optional(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp trim_optional(value), do: value
end
