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
  alias Renga.Inventory.CollectorTarget
  alias Renga.Inventory.CollectorTargetResource
  alias Renga.Inventory.Observation
  alias Renga.Inventory.ObservationReconciliation
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

  @doc """
  The current readings about each of `resource_ids`, after source precedence,
  keyed by resource id. Each entry is `%{reading, eligible?}`.

  A host agent's own readings are about the resource its latest reconciled
  report matched. A collector's readings are about the resource its target
  reports, and only while the target reports exactly one: a target with
  several resources cannot say which one a sensor measures.

  Readings are equivalent when they measure the same component of the same
  resource at the same boundary and leg, for the same quantity over the
  same window length. Among equivalent readings, precedence applies only to
  eligible ones: a native reading wins over an exporter's, then the latest.
  When none is eligible the latest is kept, so its staleness or failure can
  be shown, and it never counts.

  `:all` takes every resource that some reading is about.
  """
  def for_resources(%Scope{}, [], %DateTime{}), do: %{}

  def for_resources(%Scope{organization_id: organization_id}, resource_ids, %DateTime{} = now) do
    subjects = subjects(%Scope{organization_id: organization_id}, resource_ids)

    organization_id
    |> subject_readings(Map.keys(subjects))
    |> Enum.map(&%{reading: &1, resource_id: Map.fetch!(subjects, {&1.source_id, &1.target})})
    |> Enum.group_by(&equivalence/1)
    |> Enum.map(fn {_key, candidates} -> prefer(candidates, now) end)
    |> Enum.group_by(& &1.resource_id, &Map.delete(&1, :resource_id))
  end

  @doc """
  `{source id, target}` => resource id for every series source about one of
  `resource_ids`, by the rules `for_resources/3` describes. A host agent's
  own series have no target.
  """
  def subjects(%Scope{organization_id: organization_id}, resource_ids) do
    resource_ids = if resource_ids == :all, do: :all, else: Enum.uniq(resource_ids)

    Map.merge(
      host_subjects(organization_id, resource_ids),
      target_subjects(organization_id, resource_ids)
    )
  end

  defp equivalence(%{resource_id: resource_id, reading: reading}) do
    {resource_id, reading.component_kind, reading.component_name, reading.boundary, reading.leg,
     reading.quantity, reading.window_ms}
  end

  defp prefer(candidates, now) do
    case Enum.filter(candidates, &Reading.eligible?(&1.reading, now)) do
      [] ->
        candidates
        |> Enum.max_by(& &1.reading.event_at, DateTime)
        |> Map.put(:eligible?, false)

      eligible ->
        eligible
        |> Enum.min_by(
          &{origin_rank(&1.reading.origin), -DateTime.to_unix(&1.reading.event_at, :millisecond)}
        )
        |> Map.put(:eligible?, true)
    end
  end

  defp origin_rank("native"), do: 0
  defp origin_rank("exporter"), do: 1

  # {source id, nil} => resource id for each host source whose latest
  # reconciled report matched one of the resources.
  defp host_subjects(organization_id, resource_ids) do
    latest =
      from(observation in Observation,
        join: reconciliation in ObservationReconciliation,
        on:
          reconciliation.observation_id == observation.id and
            reconciliation.organization_id == ^organization_id,
        join: source in Source,
        on: source.id == observation.source_id,
        where: observation.organization_id == ^organization_id,
        where: source.kind == "host_agent" and reconciliation.status == "succeeded",
        where: not is_nil(reconciliation.matched_resource_id),
        distinct: observation.source_id,
        order_by: [
          asc: observation.source_id,
          desc: observation.observed_at,
          desc: observation.id
        ],
        select: %{
          source_id: observation.source_id,
          resource_id: reconciliation.matched_resource_id
        }
      )

    from(match in subquery(latest))
    |> among(resource_ids)
    |> Repo.all()
    |> Map.new(&{{&1.source_id, nil}, &1.resource_id})
  end

  # {source id, target key} => resource id for each collector target that
  # reports exactly one present resource, one of `resource_ids`.
  defp target_subjects(organization_id, resource_ids) do
    present =
      from(member in CollectorTargetResource,
        where: member.organization_id == ^organization_id,
        where: is_nil(member.withdrawn_at) or member.last_reported_at > member.withdrawn_at
      )

    single =
      from(member in subquery(present),
        group_by: member.target_id,
        having: count(member.id) == 1,
        select: %{target_id: member.target_id}
      )

    from(member in subquery(present),
      join: only in subquery(single),
      on: only.target_id == member.target_id,
      join: target in CollectorTarget,
      on: target.id == member.target_id,
      select: {target.source_id, target.key, member.resource_id}
    )
    |> among(resource_ids)
    |> Repo.all()
    |> Map.new(fn {source_id, key, resource_id} -> {{source_id, key}, resource_id} end)
  end

  defp among(query, :all), do: query
  defp among(query, resource_ids), do: where(query, [row], row.resource_id in ^resource_ids)

  defp subject_readings(_organization_id, []), do: []

  defp subject_readings(organization_id, subjects) do
    matches =
      Enum.reduce(subjects, dynamic(false), fn
        {source_id, nil}, matches ->
          dynamic(
            [reading],
            ^matches or (reading.source_id == ^source_id and is_nil(reading.target))
          )

        {source_id, target}, matches ->
          dynamic(
            [reading],
            ^matches or (reading.source_id == ^source_id and reading.target == ^target)
          )
      end)

    Reading
    |> where([reading], reading.organization_id == ^organization_id)
    |> where(^matches)
    |> preload(:source)
    |> Repo.all()
  end
end
