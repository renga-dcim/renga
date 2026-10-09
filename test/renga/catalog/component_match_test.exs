defmodule Renga.Catalog.ComponentMatchTest do
  use ExUnit.Case, async: true

  alias Renga.Catalog.ComponentMatch

  defp expected(attrs \\ %{}) do
    Map.merge(
      %{kind: "memory", name: "DIMM A1", position: "A1", attributes: %{"part_number" => "M-32G"}},
      attrs
    )
  end

  defp actual(attrs) do
    Map.merge(
      %{
        id: Ecto.UUID.generate(),
        kind: "memory",
        name: "DIMM A1",
        slot: "A1",
        path: nil,
        model: nil,
        serial_number: nil,
        part_number: "M-32G",
        attributes: %{}
      },
      attrs
    )
  end

  test "identifies a part by position and part number, else by name" do
    assert ComponentMatch.identity_matches?(expected(), actual(%{part_number: " m-32g "}))
    refute ComponentMatch.identity_matches?(expected(), actual(%{part_number: "M-64G"}))
    refute ComponentMatch.identity_matches?(expected(), actual(%{slot: "A2"}))

    by_name = expected(%{position: nil, attributes: %{}})
    assert ComponentMatch.identity_matches?(by_name, actual(%{slot: "elsewhere"}))
    refute ComponentMatch.identity_matches?(by_name, actual(%{name: "DIMM B1"}))
  end

  test "compares only the attributes a collector reported" do
    expectation = expected(%{attributes: %{"part_number" => "M-32G", "size_gb" => 32}})

    assert ComponentMatch.differences(expectation, actual(%{attributes: %{"size_gb" => 32}})) ==
             %{}

    assert ComponentMatch.differences(expectation, actual(%{attributes: %{}})) == %{}

    assert ComponentMatch.differences(expectation, actual(%{attributes: %{"size_gb" => 16}})) ==
             %{"size_gb" => %{"expected" => 32, "actual" => 16}}
  end

  test "a confirmed replacement becomes what the slot expects" do
    confirmed =
      ComponentMatch.with_confirmation(expected(), %{
        part_number: "M-32G-B",
        serial_number: "SN-9",
        model: ""
      })

    assert confirmed.attributes == %{"part_number" => "M-32G-B", "serial_number" => "SN-9"}

    replacement = actual(%{part_number: "M-32G-B", serial_number: "SN-9"})
    assert ComponentMatch.candidates(confirmed, [replacement]) == [replacement]
    assert ComponentMatch.differences(confirmed, replacement) == %{}
    assert ComponentMatch.candidates(expected(), [replacement]) == []
    assert ComponentMatch.with_confirmation(expected(), nil) == expected()
  end

  test "compares numbers by value whatever their type" do
    assert ComponentMatch.same_value?(Decimal.new("32.0"), 32)
    assert ComponentMatch.same_value?(32.0, Decimal.new("32"))
    assert ComponentMatch.same_value?(%{"a" => [1, "X"]}, %{"a" => [1, "x"]})
    refute ComponentMatch.same_value?(%{"a" => 1}, %{"a" => 1, "b" => 2})
  end
end
