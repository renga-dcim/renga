defmodule Renga.Power.Measured do
  @moduledoc """
  Measured load on power feeds (RFD 10, "Capacity and utilization" and
  "Reading identity and eligibility"), shown beside the allocated load of
  `Renga.Power.Load`.

  A feed takes one cable, so what it supplies is measured where that cable
  lands:

  * on a PDU inlet, either by the PDU's own meter for the inlet (a `feed`
    reading that declares complete coverage) or by the sum of its outlets'
    readings. One calculation uses one or the other, never both, so an
    aggregate is never added to its constituents. The sum counts only when
    every outlet the inlet feeds has an eligible reading, cabled or not:
    an uncabled outlet drawing power is still load.
  * on a device's power supply, by that supply's `supply_input` reading.

  Only compatible quantities are compared. AC capacity is in VA, so it takes
  measured apparent power, or measured real power with a measured power
  factor from the same sensor and window; DC capacity takes real power.
  Measured current is checked against the feed's rated current at its
  maximum utilization, and on a three-phase feed each leg's current comes
  only from per-leg readings: the balanced aggregate cannot show per-leg
  headroom, so a three-phase feed without all three legs measured never
  shows spare capacity.

  Only eligible readings count (`Renga.Power.Reading.eligible?/2`). Missing,
  stale, failed, or partial evidence leaves the load and headroom unknown,
  never zero, though what is known still proves a feed over its limit.
  """

  import Ecto.Query, warn: false

  alias Renga.Accounts.Scope
  alias Renga.Power.Capacity
  alias Renga.Power.Feed
  alias Renga.Power.Outlet
  alias Renga.Power.Port
  alias Renga.Power.Readings
  alias Renga.Repo
  alias Renga.Topology.Cable

  @legs ~w(a b c)

  defmodule Leg do
    @moduledoc "One measured leg of a three-phase feed, in A."
    defstruct [:leg, :current, :limit, :reading]
  end

  @enforce_keys [:feed, :capacity]
  defstruct [
    :feed,
    :capacity,
    :basis,
    :known,
    :load,
    :headroom,
    :current,
    :current_limit,
    :as_of,
    readings: [],
    legs: [],
    gaps: [],
    status: :unknown
  ]

  @doc """
  The measured load on each of `feeds` at `now`, keyed by feed id.
  """
  def for_feeds(scope, feeds, now \\ Renga.Time.utc_now_ms())

  def for_feeds(%Scope{}, [], _now), do: %{}

  def for_feeds(%Scope{organization_id: organization_id} = scope, [%Feed{} | _] = feeds, now) do
    ports = feed_ports(organization_id, Enum.map(feeds, & &1.id))
    port_list = Map.values(ports)
    outlets = fed_outlets(organization_id, Enum.map(port_list, & &1.id))
    sole_ports = sole_ports(organization_id, Enum.map(port_list, & &1.resource_id))

    readings =
      Readings.for_resources(scope, Enum.map(port_list, & &1.resource_id), now)

    Map.new(feeds, fn feed ->
      measured =
        case Map.get(ports, feed.id) do
          nil ->
            base(feed, [:no_cable])

          port ->
            context = %{
              entries: Map.get(readings, port.resource_id, []),
              sole_port?: MapSet.member?(sole_ports, port.resource_id),
              outlets: Map.get(outlets, port.id, [])
            }

            measure(feed, port, context)
        end

      {feed.id, measured}
    end)
  end

  defp base(feed, gaps) do
    capacity = Capacity.of(feed)

    %__MODULE__{
      feed: feed,
      capacity: capacity,
      current_limit: current_limit(feed),
      gaps: gaps
    }
  end

  defp measure(feed, port, %{outlets: []} = context) do
    # A device's own supply on the feed.
    entries = about_port(context, port, "supply_input")
    point = point(entries, Capacity.unit(feed))

    feed
    |> base([])
    |> put_point(:supply, point, entries)
    |> put_legs(context, port)
    |> put_status()
  end

  defp measure(feed, port, context) do
    unit = Capacity.unit(feed)

    aggregate_entries =
      context
      |> about_port(port, "feed")
      |> Enum.filter(&(&1.reading.coverage == "complete"))

    aggregate = point(aggregate_entries, unit)

    measured =
      if measured?(aggregate) do
        put_point(base(feed, []), :aggregate, aggregate, aggregate_entries)
      else
        feed |> base([]) |> constituents(context, unit) |> explain_aggregate(context, port)
      end

    measured
    |> put_legs(context, port)
    |> put_status()
  end

  # When the outlets cannot measure the feed either, why the inlet's own
  # readings could not is part of the answer.
  defp explain_aggregate(%__MODULE__{load: nil} = measured, context, port) do
    case about_port(context, port, "feed") do
      [] ->
        measured

      entries ->
        partial =
          if Enum.any?(entries, &(&1.reading.coverage != "complete")),
            do: [:partial_coverage],
            else: []

        complete = Enum.filter(entries, &(&1.reading.coverage == "complete"))
        unit = Capacity.unit(measured.feed)
        point_gaps = if complete == [], do: [], else: point(complete, unit).gaps

        gaps =
          (partial ++ point_gaps ++ measured.gaps)
          |> Enum.reject(&(&1 == :no_readings))
          |> Enum.uniq()

        %{measured | gaps: gaps}
    end
  end

  defp explain_aggregate(measured, _context, _port), do: measured

  defp constituents(measured, context, unit) do
    points =
      Enum.map(context.outlets, fn outlet ->
        entries =
          Enum.filter(context.entries, fn entry ->
            entry.reading.boundary == "outlet" and
              entry.reading.component_kind == "power_outlet" and
              entry.reading.component_name == outlet.name
          end)

        {point(entries, unit), entries}
      end)

    values = for {%{value: value}, _entries} <- points, value, do: value
    currents = for {%{current: current}, _entries} <- points, current, do: current
    used = for {_point, entries} <- points, entry <- entries, entry.eligible?, do: entry.reading
    count = length(points)
    unmeasured = count - length(values)

    gaps =
      cond do
        used == [] and not Enum.any?(points, fn {_point, entries} -> entries != [] end) ->
          [:no_readings]

        unmeasured > 0 ->
          [{:outlets_unmeasured, unmeasured} | point_gaps(points)]

        true ->
          []
      end

    known = if values != [], do: Enum.reduce(values, &Decimal.add/2)
    complete? = values != [] and unmeasured == 0

    %{
      measured
      | basis: if(used != [], do: :outlets),
        known: known,
        load: if(complete?, do: known),
        current:
          if(length(currents) == count and count > 0, do: Enum.reduce(currents, &Decimal.add/2)),
        readings: used,
        gaps: Enum.uniq(measured.gaps ++ gaps)
    }
  end

  defp point_gaps(points) do
    points
    |> Enum.flat_map(fn {point, _entries} -> point.gaps end)
    |> Enum.uniq()
  end

  defp put_point(measured, basis, point, entries) do
    used = for entry <- entries, entry.eligible?, do: entry.reading

    gaps =
      cond do
        entries == [] -> [:no_readings]
        measured?(point) and point.value -> []
        true -> point.gaps
      end

    %{
      measured
      | basis: if(used != [], do: basis),
        known: point.value,
        load: point.value,
        current: point.current,
        readings: used,
        gaps: Enum.uniq(measured.gaps ++ gaps)
    }
  end

  defp measured?(point), do: not is_nil(point.value) or not is_nil(point.current)

  # The value of one measurement point in the feed's unit, and its current,
  # from its eligible readings. The shortest window wins when several fit.
  defp point(entries, unit) do
    eligible = for entry <- entries, entry.eligible?, do: entry.reading
    stale_or_failed = Enum.any?(entries, &(not &1.eligible?))

    value = value(eligible, unit)
    current = eligible |> quantity("current") |> first_value()

    gaps =
      Enum.filter(
        [
          stale_or_failed && :ineligible,
          (is_nil(value) and unit == :va and quantity(eligible, "real_power") != []) &&
            :unconverted,
          (eligible == [] and not stale_or_failed) && :no_readings
        ],
        & &1
      )

    %{value: value, current: current, gaps: gaps}
  end

  defp value(readings, :w), do: readings |> quantity("real_power") |> first_value()

  defp value(readings, :va) do
    case readings |> quantity("apparent_power") |> first_value() do
      nil -> converted(readings)
      va -> va
    end
  end

  # Measured real power over a measured power factor from the same sensor
  # and window: both are evidence, so neither is assumed.
  defp converted(readings) do
    factors = quantity(readings, "power_factor")

    readings
    |> quantity("real_power")
    |> Enum.find_value(fn watts ->
      case Enum.find(factors, &same_window_sensor?(&1, watts)) do
        nil -> nil
        factor -> Decimal.div(watts.value, factor.value)
      end
    end)
  end

  defp same_window_sensor?(first, second) do
    first.source_id == second.source_id and first.target == second.target and
      first.sensor == second.sensor and first.window_ms == second.window_ms
  end

  defp quantity(readings, quantity) do
    readings
    |> Enum.filter(&(&1.quantity == quantity))
    |> Enum.sort_by(& &1.window_ms)
  end

  defp first_value([reading | _rest]), do: reading.value
  defp first_value([]), do: nil

  defp about_port(context, port, boundary) do
    Enum.filter(context.entries, fn %{reading: reading} ->
      reading.boundary == boundary and about?(reading, port, context.sole_port?)
    end)
  end

  # A reading names the port it measures, or names none on a device with
  # only one port.
  defp about?(%{component_kind: nil}, _port, sole_port?), do: sole_port?

  defp about?(%{component_kind: "power_port", component_name: name}, %Port{name: name}, _sole?),
    do: true

  defp about?(_reading, _port, _sole_port?), do: false

  defp put_legs(%{feed: %Feed{supply: "ac", phase: "three"} = feed} = measured, context, port) do
    entries = about_port(context, port, "leg")
    limit = current_limit(feed)

    legs =
      for leg <- @legs do
        entry =
          entries
          |> Enum.filter(&(&1.eligible? and &1.reading.leg == leg))
          |> Enum.map(& &1.reading)
          |> quantity("current")
          |> List.first()

        %Leg{leg: leg, current: entry && entry.value, limit: limit, reading: entry}
      end

    gaps = if Enum.any?(legs, &is_nil(&1.current)), do: [:legs_unmeasured], else: []

    %{
      measured
      | legs: legs,
        # The balanced aggregate says nothing about one line's current.
        current: nil,
        readings: Enum.uniq(measured.readings ++ for(leg <- legs, leg.reading, do: leg.reading)),
        gaps: Enum.uniq(measured.gaps ++ gaps)
    }
  end

  defp put_legs(measured, _context, _port), do: measured

  defp put_status(%__MODULE__{} = measured) do
    usable = measured.capacity.usable

    over? =
      (measured.known && Decimal.gt?(measured.known, usable)) ||
        (measured.current && Decimal.gt?(measured.current, measured.current_limit)) ||
        Enum.any?(measured.legs, &(&1.current && Decimal.gt?(&1.current, &1.limit)))

    legs_complete? = Enum.all?(measured.legs, &(&1.current != nil))
    proven? = measured.load != nil and legs_complete?

    status =
      cond do
        over? -> :over
        proven? and measured.gaps == [] -> :ok
        true -> :unknown
      end

    as_of =
      case measured.readings do
        [] -> nil
        readings -> readings |> Enum.map(& &1.event_at) |> Enum.min(DateTime)
      end

    %{
      measured
      | status: status,
        as_of: as_of,
        # Positive headroom needs complete, eligible coverage.
        headroom:
          if(measured.load && (status == :ok or status == :over),
            do: Decimal.sub(usable, measured.load)
          )
    }
  end

  defp current_limit(%Feed{amperage: amperage, max_utilization: max_utilization}),
    do: amperage |> Decimal.mult(max_utilization) |> Decimal.div(100)

  # The port each feed's one cable connects.
  defp feed_ports(organization_id, feed_ids) do
    Cable
    |> where([cable], cable.organization_id == ^organization_id)
    |> where([cable], cable.cable_kind == "power" and cable.power_feed_id in ^feed_ids)
    |> preload(:power_port)
    |> Repo.all()
    |> Map.new(&{&1.power_feed_id, &1.power_port})
  end

  # The current outlets each inlet feeds.
  defp fed_outlets(_organization_id, []), do: %{}

  defp fed_outlets(organization_id, port_ids) do
    Outlet
    |> where([outlet], outlet.organization_id == ^organization_id)
    |> where([outlet], outlet.inlet_port_id in ^port_ids and is_nil(outlet.retired_at))
    |> Repo.all()
    |> Enum.group_by(& &1.inlet_port_id)
  end

  # The devices among `resource_ids` with exactly one current power port.
  defp sole_ports(_organization_id, []), do: MapSet.new()

  defp sole_ports(organization_id, resource_ids) do
    Port
    |> where([port], port.organization_id == ^organization_id)
    |> where([port], port.resource_id in ^Enum.uniq(resource_ids) and is_nil(port.retired_at))
    |> group_by([port], port.resource_id)
    |> having([port], count(port.id) == 1)
    |> select([port], port.resource_id)
    |> Repo.all()
    |> MapSet.new()
  end

  @doc "The share of usable capacity a measured load takes, as a whole percent rounded up."
  def percent(%__MODULE__{load: nil}), do: nil

  def percent(%__MODULE__{load: load, capacity: capacity}) do
    load
    |> Decimal.mult(100)
    |> Decimal.div(capacity.usable)
    |> Decimal.round(0, :ceiling)
    |> Decimal.to_integer()
  end
end
