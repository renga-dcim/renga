defmodule Renga.Catalog.TemplatePatternTest do
  use ExUnit.Case, async: true

  alias Renga.Catalog.TemplatePattern

  doctest TemplatePattern

  defp template(name, position, attrs \\ %{}) do
    Map.merge(
      %{
        kind: "memory",
        name: name,
        position: position,
        required: true,
        attributes: %{"part_number" => "M-64G"},
        label: nil,
        description: nil
      },
      attrs
    )
  end

  test "expands alternatives and ranges, first group outermost" do
    assert {:ok, names} = TemplatePattern.expand("DIMM {A,B}{1..16}")
    assert length(names) == 32
    assert Enum.take(names, 2) == ["DIMM A1", "DIMM A2"]
    assert List.last(names) == "DIMM B16"
    assert TemplatePattern.expand("Bay {01..03}") == {:ok, ["Bay 01", "Bay 02", "Bay 03"]}
    assert TemplatePattern.expand("iDRAC") == {:ok, ["iDRAC"]}
  end

  test "derives positions from the brace groups unless given a pattern" do
    assert {:ok, [{"DIMM A1", "A1"}, {"DIMM A2", "A2"}]} =
             TemplatePattern.expand_slots("DIMM A{1..2}")

    assert {:ok, [{"CPU 1", "CPU1"}, {"CPU 2", "CPU2"}]} =
             TemplatePattern.expand_slots("CPU {1..2}", "CPU{1..2}")

    assert {:ok, [{"iDRAC", nil}]} = TemplatePattern.expand_slots("iDRAC", "")
    assert {:error, message} = TemplatePattern.expand_slots("CPU {1..2}", "CPU{1..3}")
    assert message =~ "3 positions for 2 names"
  end

  test "rejects malformed and oversized patterns" do
    assert {:error, _message} = TemplatePattern.expand("DIMM {A,B")
    assert {:error, _message} = TemplatePattern.expand("DIMM {A,}")
    assert {:error, _message} = TemplatePattern.expand("DIMM {9..1}")
    assert {:error, _message} = TemplatePattern.expand("  ")
    assert {:error, message} = TemplatePattern.expand("x{1..100}{1..100}")
    assert message =~ "at most"
  end

  test "compresses templates into the patterns they came from" do
    {:ok, slots} = TemplatePattern.expand_slots("DIMM {A,B}{1..16}")
    dimms = Enum.map(slots, fn {name, position} -> template(name, position) end)
    odd = template("DIMM C1", "C1", %{attributes: %{"part_number" => "M-32G"}})
    cpus = for n <- 1..2, do: template("CPU #{n}", "CPU#{n}", %{kind: "cpu", attributes: %{}})
    nic = template("iDRAC", "mgmt0", %{kind: "interface", attributes: %{}})

    groups = TemplatePattern.compress(Enum.shuffle([nic, odd | dimms ++ cpus]))

    assert Enum.map(groups, &{&1.kind, &1.name_pattern, &1.position_pattern}) == [
             {"cpu", "CPU {1..2}", "CPU{1..2}"},
             {"interface", "iDRAC", "mgmt0"},
             {"memory", "DIMM C1", "C1"},
             {"memory", "DIMM {A,B}{1..16}", "{A,B}{1..16}"}
           ]

    dimm_group = List.last(groups)
    assert length(dimm_group.templates) == 32

    assert {:ok, ^slots} =
             TemplatePattern.expand_slots(dimm_group.name_pattern, dimm_group.position_pattern)
  end

  test "keeps uneven banks apart and lists gaps" do
    names = ~w(A1 A2 A3 A4 B1 B2 B4)
    groups = TemplatePattern.compress(Enum.map(names, &template("DIMM #{&1}", &1)))

    assert Enum.map(groups, & &1.name_pattern) == ["DIMM A{1..4}", "DIMM B{1,2,4}"]
  end

  test "roundtrips sparse large slot numbers without inventing absent positions" do
    templates = [template("CPU 1", nil), template("CPU 1000000000", nil)]
    [group] = TemplatePattern.compress(templates)
    assert group.name_pattern == "CPU {1,1000000000}"

    assert TemplatePattern.expand_slots(group.name_pattern, group.position_pattern) ==
             {:ok, [{"CPU 1", nil}, {"CPU 1000000000", nil}]}
  end

  test "roundtrips mixed unlettered banks and literal pattern syntax" do
    templates = [
      template("Bay 1", "1"),
      template("Bay A1", "A1"),
      template("DIMM {A,B}", "Slot {1,2}"),
      template("Quoted 1", ~s("Slot"1)),
      template("Quoted 2", ~s("Slot"2))
    ]

    rebuilt =
      templates
      |> TemplatePattern.compress()
      |> Enum.flat_map(fn group ->
        {:ok, slots} = TemplatePattern.expand_slots(group.name_pattern, group.position_pattern)
        slots
      end)

    assert Enum.sort(rebuilt) == Enum.sort(Enum.map(templates, &{&1.name, &1.position}))
  end
end
