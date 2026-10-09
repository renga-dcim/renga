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
    Enum.filter(
      actuals,
      &(Map.get(&1, :status) != "missing" and &1.kind == expected.kind and
          identity_matches?(expected, &1))
    )
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

      (is_nil(actual_value) and field not in Map.get(expected, :confirmed_fields, [])) or
        same_value?(expected_value, actual_value)
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

    expected
    |> Map.put(:attributes, Map.merge(expected.attributes || %{}, confirmed))
    |> Map.put(:confirmed_fields, Map.keys(confirmed))
  end

  @compared_kinds ~w(cpu memory disk)
  @identity_fields ~w(part_number)

  @doc """
  Explains, in sentences, how collector reports are matched to a template
  or a group of templates with these rules, for the catalog editor. Takes
  anything with `kind`, `name`, `position`, and `attributes`; a group
  passes its patterns as name and position.
  """
  def explain(%{kind: kind}) when kind not in @compared_kinds do
    ["Collectors don't report this kind of component, so it is expected but never compared."]
  end

  def explain(%{name: name, position: position, attributes: attributes}) do
    attributes = attributes || %{}
    part_number = identity_text(attributes["part_number"])

    identity =
      case {position, part_number} do
        {nil, nil} -> "its name is #{name}"
        {nil, part_number} -> "its part number is #{part_number}"
        {position, nil} -> "its slot is #{position}"
        {position, part_number} -> "its slot is #{position} and its part number is #{part_number}"
      end

    compared = attributes |> Map.keys() |> Enum.reject(&(&1 in @identity_fields)) |> Enum.sort()

    [
      "A reported part fills this slot when #{identity}.",
      if(compared != [],
        do:
          "Its #{Enum.join(compared, ", ")} must then match; a different value is drift, and a value the collector does not report is not."
      ),
      if(part_number,
        do:
          "A part with another number in the same slot shows as a different part until it is recorded as a replacement."
      )
    ]
    |> Enum.reject(&is_nil/1)
  end

  defp identity_text(value) when is_nil(value) or is_binary(value), do: value
  defp identity_text(value), do: Renga.JSON.encode!(value)

  @doc "An observed component's value for a field an expectation names."
  def spec(actual, field) do
    reported = (Map.get(actual, :metadata) || %{})["reported_identity"] || %{}

    case Map.fetch(reported, field) do
      {:ok, value} ->
        value

      :error ->
        if field in ~w(name model slot path serial_number part_number),
          do: Map.fetch!(actual, String.to_existing_atom(field)),
          else: actual.attributes[field]
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
