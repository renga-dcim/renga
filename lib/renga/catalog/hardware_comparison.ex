defmodule Renga.Catalog.HardwareComparison do
  @moduledoc """
  A resource's expected and observed components compared slot by slot, for
  its Hardware tab (RFD 8, "Editing hardware components").

  Each row is one slot in one of four states:

    * `:match` - the expected part is there;
    * `:missing` - nothing observed fills the slot;
    * `:not_expected` - a part is observed that nothing expects;
    * `:local_change` - the slot differs on this resource: the observed part
      differs from the expectation, or a different part is in its position
      (`:drift`), several observed parts could
      fill it (`:ambiguous`), or the expectation itself was changed for
      this resource (`:override`, `:suppressed`).

  Pairing uses `Renga.Catalog.ComponentMatch` with confirmed replacements
  applied, the rules reconciliation uses for findings, so a row and its
  finding always agree. Runs of matching slots collapse so the rows that
  need attention stand out.

  Building a comparison is pure; `Renga.Catalog.hardware_comparison/2`
  loads its inputs.
  """

  alias Renga.Catalog.ComponentMatch

  @compared_kinds ~w(cpu memory disk)
  @min_run 3

  defstruct sections: [], other_expected: [], counts: %{}

  @typedoc "One slot: its expectation and observation, if any, and why it is in its state."
  @type row :: %{
          key: String.t(),
          kind: String.t(),
          label: String.t(),
          expected: struct() | nil,
          actual: struct() | nil,
          state: :match | :missing | :not_expected | :local_change,
          reasons: [atom()],
          differences: map(),
          confirmation: struct() | nil,
          gap: struct() | nil,
          resolution_key: String.t() | nil
        }

  @doc "The component kinds compared slot by slot; collectors report only these."
  def compared_kinds, do: @compared_kinds

  @doc """
  Compares `expected` components with `actuals`.

  `confirmations` comes from `Renga.Catalog.confirmations_by_expectation/2`
  and `gaps` from `Renga.Findings.component_exceptions/2`.
  """
  def build(expected, actuals, confirmations \\ %{}, gaps \\ %{}) do
    {compared, other} = Enum.split_with(expected, &(&1.kind in @compared_kinds))
    actuals = Enum.filter(actuals, &(&1.kind in @compared_kinds))

    paired =
      Enum.map(compared, fn expected ->
        confirmation = Renga.Catalog.confirmation_for(expected, confirmations)
        effective = ComponentMatch.with_confirmation(expected, confirmation)

        candidates =
          if expected.suppressed, do: [], else: ComponentMatch.candidates(effective, actuals)

        {expected, effective, confirmation, candidates}
      end)

    claimed =
      paired
      |> Enum.flat_map(fn {_expected, _effective, _confirmation, candidates} -> candidates end)
      |> Enum.frequencies_by(& &1.id)

    {expected_rows, unclaimed} =
      paired
      |> Enum.map(&expected_row(&1, claimed, gaps))
      |> pair_in_place(Enum.reject(actuals, &Map.has_key?(claimed, &1.id)))

    unexpected_rows = Enum.map(unclaimed, &unexpected_row/1)

    rows = expected_rows ++ unexpected_rows

    %__MODULE__{
      sections: sections(rows),
      other_expected: Enum.sort_by(other, &{&1.kind, natural_key(label(&1))}),
      counts:
        Map.merge(
          %{match: 0, missing: 0, not_expected: 0, local_change: 0},
          Enum.frequencies_by(rows, & &1.state)
        )
    }
  end

  @doc """
  Splits a section's rows into runs of at least #{@min_run} matching slots,
  which the tab collapses, and single rows: `{:run, rows}` or `{:row, row}`.
  """
  def groups(rows) do
    rows
    |> Enum.chunk_by(&(&1.state == :match))
    |> Enum.flat_map(fn
      [%{state: :match} | _rest] = run when length(run) >= @min_run -> [{:run, run}]
      chunk -> Enum.map(chunk, &{:row, &1})
    end)
  end

  defp expected_row({expected, effective, confirmation, candidates}, claimed, gaps) do
    key = key(expected)
    resolution_key = resolution_key(expected)
    override = if expected.exception_id, do: [:override], else: []

    {state, actual, reasons, differences} =
      case candidates do
        _any when expected.suppressed ->
          {:local_change, nil, [:suppressed], %{}}

        [] ->
          {:missing, nil, if(confirmation, do: [:replacement_pending], else: []), %{}}

        [actual] ->
          if Map.fetch!(claimed, actual.id) == 1,
            do: paired_state(effective, actual, override),
            else: ambiguous_state(candidates)

        candidates ->
          ambiguous_state(candidates)
      end

    %{
      key: key,
      kind: expected.kind,
      label: label(expected),
      expected: expected,
      effective: effective,
      actual: actual,
      state: state,
      reasons: reasons,
      differences: differences,
      confirmation: confirmation,
      gap: Map.get(gaps, {"missing_expected_component", resolution_key}),
      resolution_key: resolution_key
    }
  end

  # One observed part fills the slot and no other slot claims it.
  defp paired_state(effective, actual, override) do
    differences = ComponentMatch.differences(effective, actual)
    drift = if differences == %{}, do: [], else: [:drift]

    case drift ++ override do
      [] -> {:match, actual, [], %{}}
      reasons -> {:local_change, actual, reasons, differences}
    end
  end

  # The slot could be several observed parts, or shares its part with
  # another slot, so which part is in it is unknown.
  defp ambiguous_state(candidates),
    do: {:local_change, nil, [:ambiguous], %{"candidates" => length(candidates)}}

  # A part reported in the position of a missing slot is most likely a
  # different part in that slot, so the slot shows it as drift in one row
  # rather than as a missing slot and an unexpected part with the same
  # label. Findings still name both; recording the replacement or changing
  # the expectation resolves them together.
  defp pair_in_place(rows, unclaimed) do
    pairs =
      rows
      |> Enum.filter(&(&1.state == :missing and not is_nil(&1.expected.position)))
      |> Enum.flat_map(fn row ->
        case Enum.filter(unclaimed, &in_position?(row, &1)) do
          [actual] -> [{row.key, actual}]
          _none_or_several -> []
        end
      end)

    slots_per_part = Enum.frequencies_by(pairs, fn {_key, actual} -> actual.id end)

    pairs =
      pairs |> Enum.filter(fn {_key, actual} -> slots_per_part[actual.id] == 1 end) |> Map.new()

    paired_ids = MapSet.new(Map.values(pairs), & &1.id)

    rows =
      Enum.map(rows, fn row ->
        case Map.fetch(pairs, row.key) do
          {:ok, actual} -> in_place_row(row, actual)
          :error -> row
        end
      end)

    {rows, Enum.reject(unclaimed, &MapSet.member?(paired_ids, &1.id))}
  end

  defp in_place_row(row, actual) do
    override = if row.expected.exception_id, do: [:override], else: []

    %{
      row
      | state: :local_change,
        actual: actual,
        reasons: [:drift | row.reasons] ++ override,
        differences: ComponentMatch.differences(row.effective, actual)
    }
  end

  defp in_position?(row, actual) do
    actual.kind == row.kind and
      ComponentMatch.same_value?(row.expected.position, actual.slot || actual.path)
  end

  defp unexpected_row(actual) do
    %{
      key: "actual:" <> actual.id,
      kind: actual.kind,
      label: actual.slot || actual.path || actual.name || actual.kind,
      expected: nil,
      effective: nil,
      actual: actual,
      state: :not_expected,
      reasons: [],
      differences: %{},
      confirmation: nil,
      gap: nil,
      resolution_key: nil
    }
  end

  defp sections(rows) do
    rows
    |> Enum.group_by(& &1.kind)
    |> Enum.sort_by(fn {kind, _rows} -> Enum.find_index(@compared_kinds, &(&1 == kind)) end)
    |> Enum.map(fn {kind, rows} ->
      rows = Enum.sort_by(rows, &natural_key(&1.label))

      %{
        kind: kind,
        rows: rows,
        groups: groups(rows),
        counts: Enum.frequencies_by(rows, & &1.state)
      }
    end)
  end

  defp key(%{component_template_id: id}) when not is_nil(id), do: "template:" <> id
  defp key(%{exception_id: id}), do: "exception:" <> id

  # The key the slot's findings carry, matching reconciliation.
  defp resolution_key(%{hardware_assignment_id: assignment_id, component_template_id: id})
       when not is_nil(id),
       do: "assignment:#{assignment_id}:template:#{id}"

  defp resolution_key(%{hardware_assignment_id: assignment_id, exception_id: id}),
    do: "assignment:#{assignment_id}:exception:#{id}"

  defp label(expected), do: expected.position || expected.name

  # Orders slot names as people count them: DIMM A2 before DIMM A10.
  defp natural_key(nil), do: []

  defp natural_key(label) do
    ~r/\d+/
    |> Regex.split(label, include_captures: true, trim: true)
    |> Enum.map(fn part ->
      case Integer.parse(part) do
        {number, ""} -> {0, number}
        _text -> {1, String.downcase(part)}
      end
    end)
  end
end
