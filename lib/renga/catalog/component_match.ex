defmodule Renga.Catalog.ComponentMatch do
  @moduledoc """
  The rules that pair an expected component with an observed one.

  Reconciliation uses them to open drift, missing, and ambiguity findings,
  and the Hardware tab uses them to compare a resource slot by slot (RFD 8,
  "Editing hardware components"), so the page and the findings never
  disagree about which part is in which slot.

  An expectation identifies its part by position and, when the catalog
  names one, part number; with neither it falls back to the component name.
  Once paired, every attribute the expectation names is compared with what
  the collector reported; values a collector did not report are not drift.
  """

  @doc """
  The observed components an expectation could be: same kind, and an
  identity that matches.
  """
  def candidates(expected, actuals) do
    Enum.filter(actuals, &(&1.kind == expected.kind and identity_matches?(expected, &1)))
  end

  @doc "Whether an observed component has the identity an expectation describes."
  def identity_matches?(expected, actual) do
    expected_part_number = expected.attributes["part_number"]
    position = actual.slot || actual.path

    checks =
      [
        expected.position && same_value?(expected.position, position),
        expected_part_number && same_value?(expected_part_number, actual.part_number)
      ]
      |> Enum.reject(&is_nil/1)

    case checks do
      [] -> same_value?(expected.name, actual.name)
      checks -> Enum.all?(checks)
    end
  end

  @doc """
  How a paired observed component differs from its expectation, as
  `%{field => %{"expected" => value, "actual" => value}}`. Empty when they
  agree.
  """
  def differences(expected, actual) do
    expected.attributes
    |> Enum.reject(fn {field, expected_value} ->
      actual_value = spec(actual, field)
      is_nil(actual_value) or same_value?(expected_value, actual_value)
    end)
    |> Map.new(fn {field, expected_value} ->
      {field, %{"expected" => expected_value, "actual" => spec(actual, field)}}
    end)
  end

  @doc """
  An expectation as it stands after a confirmed replacement: the confirmed
  part's number, serial, and model replace the catalog's, so the part an
  operator installed is what the slot expects from then on.
  """
  def with_confirmation(expected, nil), do: expected

  def with_confirmation(expected, confirmation) do
    confirmed =
      [
        {"part_number", confirmation.part_number},
        {"serial_number", confirmation.serial_number},
        {"model", confirmation.model}
      ]
      |> Enum.reject(fn {_field, value} -> value in [nil, ""] end)
      |> Map.new()

    %{expected | attributes: Map.merge(expected.attributes || %{}, confirmed)}
  end

  @doc "An observed component's value for a field an expectation names."
  def spec(actual, field) do
    case field do
      "name" -> actual.name
      "model" -> actual.model
      "slot" -> actual.slot
      "path" -> actual.path
      "serial_number" -> actual.serial_number
      "part_number" -> actual.part_number
      field -> actual.attributes[field]
    end
  end

  @doc """
  Whether two reported values are the same: strings ignore case and
  surrounding space, and numbers compare by value whatever their type.
  """
  def same_value?(left, right) when is_binary(left) and is_binary(right) do
    String.downcase(String.trim(left)) == String.downcase(String.trim(right))
  end

  def same_value?(%Decimal{} = left, right) when is_integer(right),
    do: Decimal.equal?(left, Decimal.new(right))

  def same_value?(%Decimal{} = left, right) when is_float(right),
    do: Decimal.equal?(left, Decimal.from_float(right))

  def same_value?(left, %Decimal{} = right) when is_integer(left) or is_float(left),
    do: same_value?(right, left)

  def same_value?(%Decimal{} = left, %Decimal{} = right), do: Decimal.equal?(left, right)

  def same_value?(left, right)
      when is_map(left) and not is_struct(left) and is_map(right) and not is_struct(right) do
    map_size(left) == map_size(right) and
      Enum.all?(left, fn {key, left_value} ->
        case Map.fetch(right, key) do
          {:ok, right_value} -> same_value?(left_value, right_value)
          :error -> false
        end
      end)
  end

  def same_value?(left, right) when is_list(left) and is_list(right) do
    length(left) == length(right) and
      left
      |> Enum.zip(right)
      |> Enum.all?(fn {left_value, right_value} -> same_value?(left_value, right_value) end)
  end

  def same_value?(left, right), do: left == right
end
