defmodule Renga.Power.Readings do
  @moduledoc """
  The current-reading projection of power telemetry (RFD 10, "Reading
  identity and eligibility").

  Each series keeps the sample with the latest event time. A sample replayed
  late from an agent's queue, or delayed in transit, cannot replace a newer
  current value; equal event times keep the value already stored. A newer
  failed or missing sample does replace a valid one, because the latest the
  source knows is that it has no value.

  Samples whose event or window end lies implausibly far in the future are
  rejected outright: kept as current, they would block every real sample
  until the clock caught up.
  """

  import Ecto.Query, warn: false

  alias Renga.Accounts.Scope
  alias Renga.Inventory.Source
  alias Renga.Power.Reading
  alias Renga.Repo
  alias Renga.Telemetry.Payload

  # Matches `Renga.Inventory.AgentPayload`'s allowance for agent clock skew.
  @max_future_skew_seconds 300
  @insert_chunk 500

  @series [:source_id, :target, :sensor, :boundary, :quantity, :window_ms]

  @doc """
  Records validated samples from `source` received at `now`. Returns how
  many became current, how many were older than the series' current value,
  and how many were rejected for their time.

  Runs inside the caller's transaction.
  """
  def record!(%Source{} = source, samples, %DateTime{} = now) do
    latest = DateTime.add(now, @max_future_skew_seconds, :second)
    {accepted, rejected} = Enum.split_with(samples, &plausible?(&1, latest))

    rows =
      accepted
      |> Enum.map(&row(source, &1, now))
      # One statement cannot update a row twice, so a batch's own repeats
      # of a series are settled here, by the same rule.
      |> Enum.group_by(&Map.take(&1, @series))
      |> Enum.map(fn {_series, rows} -> Enum.max_by(rows, & &1.event_at, DateTime) end)

    current =
      rows
      |> Enum.chunk_every(@insert_chunk)
      |> Enum.reduce(0, fn chunk, count ->
        {inserted, _rows} =
          Repo.insert_all(Reading, chunk,
            on_conflict: newer_only(),
            conflict_target: @series
          )

        count + inserted
      end)

    %{
      current: current,
      superseded: length(accepted) - current,
      rejected: length(rejected)
    }
  end

  defp plausible?(sample, latest) do
    DateTime.compare(sample.event_at, latest) != :gt and
      DateTime.compare(sample.window_end, latest) != :gt
  end

  defp newer_only do
    from(reading in Reading,
      where: fragment("EXCLUDED.event_at") > reading.event_at,
      update: [
        set: [
          unit: fragment("EXCLUDED.unit"),
          leg: fragment("EXCLUDED.leg"),
          component_kind: fragment("EXCLUDED.component_kind"),
          component_name: fragment("EXCLUDED.component_name"),
          coverage: fragment("EXCLUDED.coverage"),
          origin: fragment("EXCLUDED.origin"),
          mapping_name: fragment("EXCLUDED.mapping_name"),
          mapping_version: fragment("EXCLUDED.mapping_version"),
          value: fragment("EXCLUDED.value"),
          state: fragment("EXCLUDED.state"),
          validity: fragment("EXCLUDED.validity"),
          window_start: fragment("EXCLUDED.window_start"),
          window_end: fragment("EXCLUDED.window_end"),
          event_at: fragment("EXCLUDED.event_at"),
          fresh_until: fragment("EXCLUDED.fresh_until"),
          received_at: fragment("EXCLUDED.received_at")
        ]
      ]
    )
  end

  defp row(source, sample, now) do
    {validity, value, state} = Payload.evidence(sample)

    %{
      id: Ecto.UUID.generate(),
      organization_id: source.organization_id,
      source_id: source.id,
      target: sample.target,
      sensor: sample.sensor,
      boundary: sample.boundary,
      quantity: sample.quantity,
      unit: sample.unit,
      window_ms: DateTime.diff(sample.window_end, sample.window_start, :millisecond),
      leg: sample.leg,
      component_kind: sample.component && sample.component.kind,
      component_name: sample.component && sample.component.name,
      coverage: sample.coverage,
      origin: sample.origin,
      mapping_name: sample.mapping_name,
      mapping_version: sample.mapping_version,
      value: value,
      state: state,
      validity: validity,
      window_start: sample.window_start,
      window_end: sample.window_end,
      event_at: sample.event_at,
      fresh_until: DateTime.add(sample.event_at, sample.fresh_for_seconds, :second),
      received_at: now
    }
  end

  @doc "Lists a source's current readings, by target and sensor."
  def list_source_readings(%Scope{organization_id: organization_id}, source_id) do
    Reading
    |> where([reading], reading.organization_id == ^organization_id)
    |> where([reading], reading.source_id == ^source_id)
    |> order_by([reading],
      asc_nulls_first: reading.target,
      asc: reading.sensor,
      asc: reading.boundary,
      asc: reading.quantity,
      asc: reading.window_ms
    )
    |> Repo.all()
  end
end
