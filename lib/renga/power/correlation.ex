defmodule Renga.Power.Correlation do
  @moduledoc """
  Suggested connections (RFD 10, "Suggested connections"): which outlet a
  power supply is plugged into, from how their readings move together.

  The correlation window is separate from the current-reading projection
  and any chart store. `record!/3` keeps the valid outlet and supply-input
  samples of each telemetry batch, at most one per series per minute and
  none older than 24 hours, so no series holds more than 1,440.

  `conditions/4` compares every unconnected outlet with every unconnected
  supply in the same rack. A pair qualifies in one of two ways:

    * By load. The two series need 30 minutes of overlapping coverage with
      80% of the expected one-minute samples paired, each pair taken within
      one sampling interval. They must change together, in the same
      direction, at three or more distinct steps, and their step-to-step
      changes must correlate. A step at which other series in the rack move
      the same way is common-mode, such as a feed-wide event, and does not
      count.
    * By state. The outlet turns off or loses its draw within one interval
      of the supply losing input, and no other candidate in the rack changes
      at that time.

  A suggestion is ambiguous, and nothing opens, when another candidate
  scores within the confidence margin or when an outlet or supply would be
  suggested twice. A suggestion opens a `suggested_connection` finding on
  the supply's device with an evidence bundle: the paired samples' identities,
  values, times, and boundaries, and the score. That bundle never changes,
  so the finding's basis survives the samples leaving the window. The
  finding stays open while both ends remain unconnected.

  Suggestions never change a connection. Recording one is an operator's
  confirmed power cable claim, made from the finding.
  """

  import Ecto.Query, warn: false

  alias Renga.Accounts.Scope
  alias Renga.DCIM.CurrentPlacement
  alias Renga.Inventory.Resource
  alias Renga.Inventory.Source
  alias Renga.Power.CorrelationSample
  alias Renga.Power.Finding
  alias Renga.Power.Readings
  alias Renga.Repo
  alias Renga.Telemetry.Payload
  alias Renga.Topology.Cable

  @kind "suggested_connection"
  @window_seconds 86_400
  @interval_seconds 60
  @min_overlap_seconds 1_800
  @min_presence 0.8
  @min_transitions 3
  @min_score 0.8
  @margin 0.1
  @max_evidence 20
  # Matches `Renga.Power.Readings`' allowance for agent clock skew.
  @max_future_skew_seconds 300
  @insert_chunk 500
  # A change smaller than this, or than a tenth of the level, is noise.
  @transition_floor %{"real_power" => 10.0, "current" => 0.1}
  # Below these an outlet draws nothing.
  @draw_floor %{"real_power" => 5.0, "current" => 0.05}

  @series_minute [:source_id, :target, :sensor, :boundary, :quantity, :minute]

  def kind, do: @kind

  @doc """
  Keeps the window's samples from a batch `source` sent, received at `now`.
  Runs inside the caller's transaction.
  """
  def record!(%Source{} = source, samples, %DateTime{} = now) do
    oldest = DateTime.add(now, -@window_seconds, :second)
    latest = DateTime.add(now, @max_future_skew_seconds, :second)

    samples
    |> Enum.filter(
      &(candidate?(&1) and DateTime.compare(&1.event_at, oldest) == :gt and
          DateTime.compare(&1.event_at, latest) != :gt)
    )
    |> Enum.flat_map(fn sample ->
      case Payload.evidence(sample) do
        {"valid", value, state} -> [row(source, sample, value, state)]
        _unusable -> []
      end
    end)
    |> Enum.group_by(&Map.take(&1, @series_minute))
    |> Enum.map(fn {_minute, rows} -> Enum.max_by(rows, & &1.event_at, DateTime) end)
    |> Enum.chunk_every(@insert_chunk)
    |> Enum.each(
      &Repo.insert_all(CorrelationSample, &1,
        on_conflict: newer_only(),
        conflict_target: @series_minute
      )
    )
  end

  defp candidate?(%{boundary: "outlet", component: %{kind: "power_outlet"}, quantity: quantity}),
    do: quantity in ~w(real_power current state)

  defp candidate?(%{boundary: "supply_input", quantity: quantity}),
    do: quantity in ~w(real_power state)

  defp candidate?(_sample), do: false

  defp row(source, sample, value, state) do
    %{
      id: Ecto.UUID.generate(),
      organization_id: source.organization_id,
      source_id: source.id,
      target: sample.target,
      sensor: sample.sensor,
      boundary: sample.boundary,
      quantity: sample.quantity,
      component_kind: sample.component && sample.component.kind,
      component_name: sample.component && sample.component.name,
      minute: minute(sample.event_at),
      event_at: sample.event_at,
      value: value,
      state: state
    }
  end

  defp minute(%DateTime{} = at), do: %{DateTime.truncate(at, :second) | second: 0}

  defp newer_only do
    from(sample in CorrelationSample,
      where: fragment("EXCLUDED.event_at") > sample.event_at,
      update: [
        set: [
          component_kind: fragment("EXCLUDED.component_kind"),
          component_name: fragment("EXCLUDED.component_name"),
          event_at: fragment("EXCLUDED.event_at"),
          value: fragment("EXCLUDED.value"),
          state: fragment("EXCLUDED.state")
        ]
      ]
    )
  end

  @doc """
  The `suggested_connection` conditions at `now`, as finding attributes for
  `Renga.Power.FindingReconciler`, given the organization's current ports
  and outlets. Open suggestions whose ends are both still unconnected are
  kept with their original evidence; new ones open only for ends no open
  suggestion names. Also drops samples that have left the window.
  """
  def conditions(%Scope{organization_id: organization_id} = scope, ports, outlets, now) do
    prune!(organization_id, now)
    {cabled_ports, cabled_outlets} = cabled(organization_id)
    free_ports = Enum.reject(ports, &MapSet.member?(cabled_ports, &1.id))
    free_outlets = Enum.reject(outlets, &MapSet.member?(cabled_outlets, &1.id))
    free_port_ids = MapSet.new(free_ports, & &1.id)
    free_outlet_ids = MapSet.new(free_outlets, & &1.id)

    kept =
      for finding <- open_suggestions(organization_id),
          MapSet.member?(free_port_ids, finding.details["port_id"]),
          MapSet.member?(free_outlet_ids, finding.details["outlet_id"]) do
        Map.take(finding, [:resource_id, :kind, :resolution_key, :message, :details])
      end

    claimed =
      MapSet.new(kept, & &1.details["port_id"])
      |> MapSet.union(MapSet.new(kept, & &1.details["outlet_id"]))

    opened =
      scope
      |> suggestions(ports, free_ports, free_outlets, now)
      |> Enum.reject(
        &(MapSet.member?(claimed, &1.port.id) or MapSet.member?(claimed, &1.outlet.id))
      )
      |> condition_attrs(organization_id)

    kept ++ opened
  end

  defp prune!(organization_id, now) do
    oldest = minute(DateTime.add(now, -@window_seconds, :second))

    CorrelationSample
    |> where([sample], sample.organization_id == ^organization_id and sample.minute <= ^oldest)
    |> Repo.delete_all()
  end

  defp cabled(organization_id) do
    cables =
      Cable
      |> where([cable], cable.organization_id == ^organization_id and cable.cable_kind == "power")
      |> select([cable], {cable.power_port_id, cable.power_outlet_id})
      |> Repo.all()

    {MapSet.new(cables, &elem(&1, 0)), MapSet.new(cables, &elem(&1, 1))}
  end

  defp open_suggestions(organization_id) do
    Finding
    |> where([finding], finding.organization_id == ^organization_id)
    |> where([finding], finding.status == "open" and finding.kind == @kind)
    |> Repo.all()
  end

  @doc """
  The connections the window suggests at `now` between `free_ports` and
  `free_outlets`, unconnected ends sharing a rack. `ports` are all current
  ports, to tell a device's sole port. Each is `%{port, outlet, basis,
  score, steps}`.
  """
  def suggestions(%Scope{} = scope, ports, free_ports, free_outlets, now) do
    racks = racks(scope, Enum.map(free_ports ++ free_outlets, & &1.resource_id))

    groups =
      (Enum.map(free_ports, &{:port, &1}) ++ Enum.map(free_outlets, &{:outlet, &1}))
      |> Enum.filter(fn {_end, endpoint} -> Map.has_key?(racks, endpoint.resource_id) end)
      |> Enum.group_by(fn {_end, endpoint} -> Map.fetch!(racks, endpoint.resource_id) end)
      |> Enum.map(fn {_rack, ends} ->
        {for({:port, port} <- ends, do: port), for({:outlet, outlet} <- ends, do: outlet)}
      end)
      |> Enum.filter(fn {rack_ports, rack_outlets} -> rack_ports != [] and rack_outlets != [] end)

    case groups do
      [] ->
        []

      groups ->
        series = load_series(scope, groups, now)
        sole_ports = sole_ports(ports)
        Enum.flat_map(groups, &rack_suggestions(&1, series, sole_ports))
    end
  end

  defp racks(%Scope{organization_id: organization_id}, resource_ids) do
    CurrentPlacement
    |> where([placement], placement.organization_id == ^organization_id)
    |> where([placement], placement.resource_id in ^Enum.uniq(resource_ids))
    |> where([placement], not is_nil(placement.rack_id))
    |> select([placement], {placement.resource_id, placement.rack_id})
    |> Repo.all()
    |> Map.new()
  end

  defp sole_ports(ports) do
    ports
    |> Enum.group_by(& &1.resource_id)
    |> Enum.filter(fn {_resource_id, device_ports} -> length(device_ports) == 1 end)
    |> MapSet.new(fn {resource_id, _ports} -> resource_id end)
  end

  # Every window sample about the groups' devices, as series keyed by
  # resource, boundary, component, and quantity.
  defp load_series(%Scope{organization_id: organization_id} = scope, groups, now) do
    resource_ids =
      groups
      |> Enum.flat_map(fn {ports, outlets} -> ports ++ outlets end)
      |> Enum.map(& &1.resource_id)
      |> Enum.uniq()

    subjects = Readings.subjects(scope, resource_ids)
    oldest = minute(DateTime.add(now, -@window_seconds, :second))

    subjects
    |> Map.keys()
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
    |> Enum.flat_map(fn {source_id, targets} ->
      CorrelationSample
      |> where([sample], sample.organization_id == ^organization_id)
      |> where([sample], sample.source_id == ^source_id and sample.minute > ^oldest)
      |> where_targets(targets)
      |> Repo.all()
    end)
    |> Enum.group_by(fn sample ->
      {Map.fetch!(subjects, {sample.source_id, sample.target}), sample.source_id, sample.target,
       sample.sensor, sample.boundary, sample.quantity}
    end)
    |> Enum.map(fn {{resource_id, _source_id, _target, _sensor, boundary, quantity}, samples} ->
      [first | _rest] = samples

      %{
        resource_id: resource_id,
        boundary: boundary,
        quantity: quantity,
        component_kind: first.component_kind,
        component_name: first.component_name,
        points: samples |> Enum.map(&point/1) |> Enum.sort_by(& &1.at)
      }
    end)
  end

  defp where_targets(query, targets) do
    {host, collector} = Enum.split_with(targets, &is_nil/1)

    case {host, collector} do
      {[], targets} -> where(query, [sample], sample.target in ^targets)
      {_host, []} -> where(query, [sample], is_nil(sample.target))
      {_host, targets} -> where(query, [s], is_nil(s.target) or s.target in ^targets)
    end
  end

  defp point(%CorrelationSample{} = sample) do
    %{
      at: DateTime.to_unix(sample.event_at, :millisecond) / 1_000,
      value: sample.value && Decimal.to_float(sample.value),
      state: sample.state,
      sample: sample
    }
  end

  defp rack_suggestions({ports, outlets}, series, sole_ports) do
    ports = Enum.map(ports, &port_series(&1, series, sole_ports))
    outlets = Enum.map(outlets, &outlet_series(&1, series))

    (by_load(ports, outlets) ++ by_state(ports, outlets))
    |> unambiguous()
  end

  # A supply's readings name its port, or name none on a sole-port device.
  defp port_series(port, series, sole_ports) do
    mine =
      Enum.filter(series, fn series ->
        series.resource_id == port.resource_id and series.boundary == "supply_input" and
          ((series.component_kind == "power_port" and series.component_name == port.name) or
             (is_nil(series.component_kind) and MapSet.member?(sole_ports, port.resource_id)))
      end)

    %{endpoint: port, load: longest(mine, ["real_power"]), state: longest(mine, ["state"])}
  end

  defp outlet_series(outlet, series) do
    mine =
      Enum.filter(series, fn series ->
        series.resource_id == outlet.resource_id and series.boundary == "outlet" and
          series.component_name == outlet.name
      end)

    %{
      endpoint: outlet,
      load: longest(mine, ["real_power"]) || longest(mine, ["current"]),
      state: longest(mine, ["state"])
    }
  end

  defp longest(series, quantities) do
    series
    |> Enum.filter(&(&1.quantity in quantities))
    |> Enum.max_by(&length(&1.points), fn -> nil end)
  end

  ## By load

  defp by_load(ports, outlets) do
    ports = Enum.filter(ports, & &1.load)
    outlets = Enum.filter(outlets, & &1.load)
    port_moves = Map.new(ports, &{&1.endpoint.id, moves(&1.load)})
    outlet_moves = Map.new(outlets, &{&1.endpoint.id, moves(&1.load)})

    scored =
      for outlet <- outlets,
          port <- ports,
          port.endpoint.resource_id != outlet.endpoint.resource_id,
          result <- [score(outlet, port, others(outlet_moves, outlet), others(port_moves, port))],
          result != nil,
          do: result

    Enum.filter(scored, fn result ->
      length(result.steps) >= @min_transitions and result.score >= @min_score and
        not Enum.any?(scored, &rival?(&1, result))
    end)
  end

  defp others(moves, side), do: moves |> Map.delete(side.endpoint.id) |> Map.values()

  # Another pairing of either end that scores within the margin.
  defp rival?(other, result) do
    other != result and
      (other.port.id == result.port.id or other.outlet.id == result.outlet.id) and
      other.score >= result.score - @margin
  end

  # Each step of a series between points no more than two intervals apart,
  # as minute => direction, for telling common-mode steps.
  defp moves(%{quantity: quantity, points: points}) do
    points
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.filter(fn [before, later] -> later.at - before.at <= 2 * @interval_seconds end)
    |> Enum.flat_map(fn [before, later] ->
      case direction(quantity, before.value, later.value) do
        0 -> []
        direction -> [{trunc(later.at / @interval_seconds), direction}]
      end
    end)
    |> Map.new()
  end

  defp direction(quantity, before, later) do
    change = later - before
    floor = Map.fetch!(@transition_floor, quantity)

    cond do
      abs(change) < max(floor, 0.1 * max(abs(before), abs(later))) -> 0
      change > 0 -> 1
      true -> -1
    end
  end

  # Scores an outlet against a supply, or nil when their series never
  # overlap enough to compare or never move together.
  defp score(outlet, port, outlet_others, port_others) do
    pairs = pair(outlet.load.points, port.load.points)

    with true <- covered?(outlet.load.points, port.load.points, pairs),
         steps = steps(pairs),
         steps = Enum.reject(steps, &common_mode?(&1, outlet, port, outlet_others, port_others)),
         moved = Enum.filter(steps, &moved_together?(&1, outlet, port)),
         true <- moved != [] do
      %{
        basis: "load",
        port: port.endpoint,
        outlet: outlet.endpoint,
        score: pearson(Enum.map(steps, & &1.outlet_change), Enum.map(steps, & &1.port_change)),
        steps: distinct(moved)
      }
    else
      _incomparable -> nil
    end
  end

  # Pairs each outlet point with the nearest unused supply point within one
  # interval of it.
  defp pair(outlet_points, port_points) do
    by_minute = Map.new(port_points, &{trunc(&1.at / @interval_seconds), &1})

    {pairs, _used} =
      Enum.reduce(outlet_points, {[], MapSet.new()}, fn point, {pairs, used} ->
        minute = trunc(point.at / @interval_seconds)

        nearest =
          [minute, minute - 1, minute + 1]
          |> Enum.map(&Map.get(by_minute, &1))
          |> Enum.reject(&(is_nil(&1) or MapSet.member?(used, &1.at)))
          |> Enum.filter(&(abs(&1.at - point.at) <= @interval_seconds))
          |> Enum.min_by(&abs(&1.at - point.at), fn -> nil end)

        case nearest do
          nil -> {pairs, used}
          match -> {[{point, match} | pairs], MapSet.put(used, match.at)}
        end
      end)

    Enum.reverse(pairs)
  end

  defp covered?([], _port_points, _pairs), do: false
  defp covered?(_outlet_points, [], _pairs), do: false

  defp covered?(outlet_points, port_points, pairs) do
    start = max(hd(outlet_points).at, hd(port_points).at)
    stop = min(List.last(outlet_points).at, List.last(port_points).at)
    expected = trunc((stop - start) / @interval_seconds) + 1
    within = Enum.count(pairs, fn {point, _match} -> point.at >= start and point.at <= stop end)

    stop - start >= @min_overlap_seconds and within >= @min_presence * expected
  end

  defp steps(pairs) do
    pairs
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.filter(fn [{before, _}, {later, _}] ->
      later.at - before.at <= 2 * @interval_seconds
    end)
    |> Enum.map(fn [{outlet_before, port_before}, {outlet_after, port_after}] ->
      %{
        minute: trunc(outlet_after.at / @interval_seconds),
        outlet: [outlet_before, outlet_after],
        port: [port_before, port_after],
        outlet_change: outlet_after.value - outlet_before.value,
        port_change: port_after.value - port_before.value
      }
    end)
  end

  defp moved_together?(step, outlet, port) do
    [outlet_before, outlet_after] = step.outlet
    [port_before, port_after] = step.port
    outlet_direction = direction(outlet.load.quantity, outlet_before.value, outlet_after.value)

    outlet_direction != 0 and
      outlet_direction == direction(port.load.quantity, port_before.value, port_after.value)
  end

  # A step at which at least two other series of either side, and at least
  # half of them, moved the same way at about the same time.
  defp common_mode?(step, outlet, port, outlet_others, port_others) do
    [outlet_before, outlet_after] = step.outlet
    [port_before, port_after] = step.port

    crowd?(
      outlet_others,
      step.minute,
      direction(outlet.load.quantity, outlet_before.value, outlet_after.value)
    ) or
      crowd?(
        port_others,
        step.minute,
        direction(port.load.quantity, port_before.value, port_after.value)
      )
  end

  defp crowd?(_others, _minute, 0), do: false

  defp crowd?(others, minute, direction) do
    alike =
      Enum.count(others, fn moves ->
        Enum.any?((minute - 1)..(minute + 1), &(Map.get(moves, &1) == direction))
      end)

    alike >= 2 and alike * 2 >= length(others)
  end

  # Steps at least two intervals apart, so one slow ramp counts once.
  defp distinct(steps) do
    steps
    |> Enum.reduce([], fn
      step, [last | _rest] = kept when step.minute - last.minute < 2 -> kept
      step, kept -> [step | kept]
    end)
    |> Enum.reverse()
  end

  defp pearson(xs, ys) do
    count = length(xs)

    if count < 2 do
      0.0
    else
      mean_x = Enum.sum(xs) / count
      mean_y = Enum.sum(ys) / count

      {covariance, var_x, var_y} =
        Enum.zip_reduce(xs, ys, {0.0, 0.0, 0.0}, fn x, y, {covariance, var_x, var_y} ->
          dx = x - mean_x
          dy = y - mean_y
          {covariance + dx * dy, var_x + dx * dx, var_y + dy * dy}
        end)

      if var_x == 0 or var_y == 0, do: 0.0, else: covariance / :math.sqrt(var_x * var_y)
    end
  end

  ## By state

  defp by_state(ports, outlets) do
    outlet_events = Enum.flat_map(outlets, &outlet_events/1)
    port_events = Enum.flat_map(ports, &port_events/1)

    for outlet_event <- outlet_events,
        port_event <- port_events,
        port_event.endpoint.resource_id != outlet_event.endpoint.resource_id,
        near?(outlet_event, port_event),
        alone?(outlet_event, outlet_events),
        alone?(port_event, port_events) do
      %{
        basis: "state",
        port: port_event.endpoint,
        outlet: outlet_event.endpoint,
        score: 1.0,
        steps: [%{outlet: outlet_event.points, port: port_event.points}]
      }
    end
  end

  # An outlet turning off, or its draw falling to nothing.
  defp outlet_events(%{endpoint: outlet} = side) do
    off =
      for [before, later] <- adjacent(side.state),
          before.state == "on" and later.state == "off",
          do: %{endpoint: outlet, at: later.at, points: [before, later]}

    lost =
      for [before, later] <- adjacent(side.load),
          floor <- [Map.fetch!(@draw_floor, side.load.quantity)],
          before.value >= floor and later.value < floor,
          not Enum.any?(off, &(abs(&1.at - later.at) <= 2 * @interval_seconds)),
          do: %{endpoint: outlet, at: later.at, points: [before, later]}

    off ++ lost
  end

  defp port_events(%{endpoint: port} = side) do
    for [before, later] <- adjacent(side.state),
        before.state != "no_input" and later.state == "no_input",
        do: %{endpoint: port, at: later.at, points: [before, later]}
  end

  defp adjacent(nil), do: []

  defp adjacent(%{points: points}) do
    points
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.filter(fn [before, later] -> later.at - before.at <= 2 * @interval_seconds end)
  end

  defp near?(first, second), do: abs(first.at - second.at) <= @interval_seconds

  # No other end of the same kind changed at the same time.
  defp alone?(event, events) do
    not Enum.any?(events, &(&1.endpoint.id != event.endpoint.id and near?(&1, event)))
  end

  ## Choosing

  # One suggestion per pair, preferring state evidence, and none for an end
  # that two different pairs would name.
  defp unambiguous(results) do
    results =
      results
      |> Enum.group_by(&{&1.port.id, &1.outlet.id})
      |> Enum.map(fn {_pair, results} -> Enum.min_by(results, &basis_rank(&1.basis)) end)

    port_counts = Enum.frequencies_by(results, & &1.port.id)
    outlet_counts = Enum.frequencies_by(results, & &1.outlet.id)

    Enum.filter(results, &(port_counts[&1.port.id] == 1 and outlet_counts[&1.outlet.id] == 1))
  end

  defp basis_rank("state"), do: 0
  defp basis_rank("load"), do: 1

  ## Findings

  defp condition_attrs([], _organization_id), do: []

  defp condition_attrs(suggestions, organization_id) do
    resource_ids =
      Enum.flat_map(suggestions, &[&1.port.resource_id, &1.outlet.resource_id])

    names =
      Resource
      |> where([resource], resource.organization_id == ^organization_id)
      |> where([resource], resource.id in ^Enum.uniq(resource_ids))
      |> select([resource], {resource.id, coalesce(resource.display_name, resource.name)})
      |> Repo.all()
      |> Map.new()

    Enum.map(suggestions, fn suggestion ->
      %{port: port, outlet: outlet} = suggestion
      pdu = Map.get(names, outlet.resource_id)

      %{
        resource_id: port.resource_id,
        kind: @kind,
        resolution_key: "#{port.id}:#{outlet.id}",
        message:
          "#{port.name} may be plugged into #{pdu} outlet #{outlet.name}. " <> because(suggestion),
        details: %{
          "port_id" => port.id,
          "port" => port.name,
          "outlet_id" => outlet.id,
          "outlet" => outlet.name,
          "outlet_resource_id" => outlet.resource_id,
          "outlet_resource" => pdu,
          "basis" => suggestion.basis,
          "score" => Float.round(suggestion.score, 3),
          "steps" =>
            suggestion.steps
            |> Enum.take(@max_evidence)
            |> Enum.map(
              &%{
                "outlet" => Enum.map(&1.outlet, fn point -> evidence(point.sample) end),
                "supply" => Enum.map(&1.port, fn point -> evidence(point.sample) end)
              }
            )
        }
      }
    end)
  end

  defp because(%{basis: "state"}), do: "The outlet lost its draw as the supply lost input."

  defp because(%{basis: "load", steps: steps}),
    do: "Their readings rose and fell together at #{length(steps)} distinct times."

  defp evidence(%CorrelationSample{} = sample) do
    %{
      "source_id" => sample.source_id,
      "target" => sample.target,
      "sensor" => sample.sensor,
      "boundary" => sample.boundary,
      "quantity" => sample.quantity,
      "event_at" => DateTime.to_iso8601(sample.event_at)
    }
    |> Map.merge(
      if sample.quantity == "state",
        do: %{"state" => sample.state},
        else: %{"value" => sample.value |> Decimal.normalize() |> Decimal.to_string(:normal)}
    )
  end
end
