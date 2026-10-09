defmodule Renga.Catalog.HardwareComparisonTest do
  use ExUnit.Case, async: true

  alias Renga.Catalog.HardwareComparison

  @assignment "assignment-1"

  defp expected(name, attrs \\ %{}) do
    Map.merge(
      %{
        id: Ecto.UUID.generate(),
        kind: "memory",
        name: name,
        position: name,
        attributes: %{"part_number" => "M-32G"},
        suppressed: false,
        required: true,
        hardware_assignment_id: @assignment,
        component_template_id: "tpl-" <> name,
        exception_id: nil
      },
      attrs
    )
  end

  defp actual(slot, attrs \\ %{}) do
    Map.merge(
      %{
        id: Ecto.UUID.generate(),
        kind: "memory",
        name: slot,
        slot: slot,
        path: nil,
        model: nil,
        serial_number: nil,
        part_number: "M-32G",
        attributes: %{}
      },
      attrs
    )
  end

  defp states(comparison) do
    for section <- comparison.sections,
        row <- section.rows,
        do: {row.label, row.state, row.reasons}
  end

  test "puts every slot in one of four states, ordered as people count slots" do
    comparison =
      HardwareComparison.build(
        [
          expected("A10"),
          expected("A2"),
          expected("A1"),
          expected("A3", %{exception_id: "exc-1"}),
          expected("A4", %{suppressed: true, exception_id: "exc-2"}),
          expected("A5", %{attributes: %{"part_number" => "M-32G", "speed" => 3200}})
        ],
        [
          actual("A1"),
          actual("A3"),
          actual("A5", %{attributes: %{"speed" => 2933}}),
          actual("A10"),
          actual("B1")
        ]
      )

    assert states(comparison) == [
             {"A1", :match, []},
             {"A2", :missing, []},
             {"A3", :local_change, [:override]},
             {"A4", :local_change, [:suppressed]},
             {"A5", :local_change, [:drift]},
             {"A10", :match, []},
             {"B1", :not_expected, []}
           ]

    assert comparison.counts == %{match: 2, missing: 1, not_expected: 1, local_change: 3}

    [section] = comparison.sections
    a5 = Enum.find(section.rows, &(&1.label == "A5"))
    assert a5.differences == %{"speed" => %{"expected" => 3200, "actual" => 2933}}
    assert Enum.find(section.rows, &(&1.label == "A2")).key == "template:tpl-A2"

    assert Enum.find(section.rows, &(&1.label == "A2")).resolution_key ==
             "assignment:assignment-1:template:tpl-A2"
  end

  test "marks a slot two observed parts could fill as ambiguous" do
    comparison =
      HardwareComparison.build(
        [expected("CPU", %{kind: "cpu", position: nil, attributes: %{}})],
        [actual("x", %{kind: "cpu", name: "CPU"}), actual("y", %{kind: "cpu", name: "CPU"})]
      )

    assert [{"CPU", :local_change, [:ambiguous]}] = states(comparison)
  end

  test "a confirmed replacement is expected; until reported the slot waits for it" do
    dimm = expected("A1")

    confirmations = %{
      {:template, "tpl-A1"} => %{part_number: "M-32G-B", serial_number: nil, model: nil}
    }

    waiting = HardwareComparison.build([dimm], [actual("A1")], confirmations)
    assert [{"A1", :local_change, [:drift, :replacement_pending]}] = states(waiting)

    assert [%{differences: %{"part_number" => %{"actual" => "M-32G"}}}] =
             hd(waiting.sections).rows

    reported =
      HardwareComparison.build([dimm], [actual("A1", %{part_number: "M-32G-B"})], confirmations)

    assert [{"A1", :match, []}] = states(reported)
  end

  test "a different part in a missing slot's position is drift in that slot" do
    comparison =
      HardwareComparison.build(
        [expected("A1"), expected("A2"), expected("A3")],
        [actual("A1", %{part_number: "M-16G"}), actual("A9", %{part_number: "M-16G"})]
      )

    assert states(comparison) == [
             {"A1", :local_change, [:drift]},
             {"A2", :missing, []},
             {"A3", :missing, []},
             {"A9", :not_expected, []}
           ]
  end

  test "shows a slot that is out until a date" do
    gap = %{exception_expires_at: ~U[2099-01-01 00:00:00Z]}
    gaps = %{{"missing_expected_component", "assignment:assignment-1:template:tpl-A1"} => gap}

    [section] = HardwareComparison.build([expected("A1")], [], %{}, gaps).sections
    assert [%{state: :missing, gap: ^gap}] = section.rows
  end

  test "collapses runs of at least three matching slots" do
    names = ~w(A1 A2 A3 A4 A5)

    comparison =
      HardwareComparison.build(
        Enum.map(names, &expected/1),
        Enum.map(names -- ["A4"], &actual/1)
      )

    [section] = comparison.sections

    assert [{:run, run}, {:row, %{label: "A4"}}, {:row, %{label: "A5"}}] = section.groups
    assert Enum.map(run, & &1.label) == ~w(A1 A2 A3)
  end

  test "lists expectations collectors do not report apart from the comparison" do
    comparison =
      HardwareComparison.build(
        [expected("eth0", %{kind: "interface"}), expected("A1")],
        [actual("A1")]
      )

    assert [%{name: "eth0"}] = comparison.other_expected
    assert [{"A1", :match, []}] = states(comparison)
  end
end
