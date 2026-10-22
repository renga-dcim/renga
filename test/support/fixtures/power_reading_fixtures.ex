defmodule Renga.PowerReadingFixtures do
  @moduledoc """
  Test helpers for power readings (RFD 10 phase 4): a collector stream whose
  target reports a resource, and current readings recorded as telemetry
  intake records them.
  """

  alias Renga.Inventory.CollectorTarget
  alias Renga.Inventory.CollectorTargetResource
  alias Renga.Inventory.Source
  alias Renga.Power.Readings
  alias Renga.Repo

  @doc "A `power_poller` stream on a new checked-in installation."
  def power_stream_fixture(organization, kind \\ "power_poller") do
    agent = Renga.JobsFixtures.agent_fixture(organization)

    %Source{organization_id: organization.id, agent_id: agent.id, collector_id: "pdus"}
    |> Source.changeset(%{
      kind: kind,
      name: "#{kind}-#{System.unique_integer([:positive])}",
      status: "active"
    })
    |> Repo.insert!()
  end

  @doc "Records that `source`'s target `key` reports `resource`, as a collector report would."
  def target_resource_fixture(%Source{} = source, key, resource) do
    now = Renga.Time.utc_now_ms()

    target =
      Repo.get_by(CollectorTarget, source_id: source.id, key: key) ||
        Repo.insert!(%CollectorTarget{
          organization_id: source.organization_id,
          source_id: source.id,
          key: key,
          status: "reachable",
          last_reported_at: now,
          last_reachable_at: now
        })

    Repo.insert!(%CollectorTargetResource{
      organization_id: source.organization_id,
      source_id: source.id,
      target_id: target.id,
      resource_id: resource.id,
      first_reported_at: now,
      last_reported_at: now
    })

    target
  end

  @doc """
  Records one sample from `source` as current, timed `now` unless given.
  Attributes follow the parsed telemetry sample, such as `boundary:`,
  `quantity:`, `value:`, and `component: {"power_outlet", "3"}`.
  """
  def reading_fixture(%Source{} = source, attrs) do
    attrs = Map.new(attrs)
    event_at = Map.get(attrs, :event_at, Renga.Time.utc_now_ms())
    window = Map.get(attrs, :window_seconds, 0)
    quantity = Map.get(attrs, :quantity, "real_power")

    component =
      case Map.get(attrs, :component) do
        {kind, name} -> %{kind: kind, name: name}
        nil -> nil
      end

    sample = %{
      target: Map.get(attrs, :target),
      sensor: Map.get(attrs, :sensor, "sensor-#{System.unique_integer([:positive])}"),
      boundary: Map.get(attrs, :boundary, "outlet"),
      quantity: quantity,
      unit: Map.get(attrs, :unit, Map.get(Renga.Power.Reading.units(), quantity)),
      leg: Map.get(attrs, :leg),
      component: component,
      coverage: Map.get(attrs, :coverage),
      origin: Map.get(attrs, :origin, "native"),
      status: Map.get(attrs, :status, "valid"),
      value: Map.get(attrs, :value),
      state: Map.get(attrs, :state),
      window_start: DateTime.add(event_at, -window, :second),
      window_end: event_at,
      event_at: event_at,
      mapping_name: Map.get(attrs, :mapping_name, "test"),
      mapping_version: 1,
      fresh_for_seconds: Map.get(attrs, :fresh_for_seconds, 180)
    }

    Readings.record!(source, [sample], Renga.Time.utc_now_ms())
  end
end
