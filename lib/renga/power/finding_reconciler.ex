defmodule Renga.Power.FindingReconciler do
  @moduledoc """
  Opens and resolves an organization's power findings (RFD 10, "Findings")
  from its current power model and eligible readings.

  Every condition is recomputed from scratch: an open finding whose
  condition still holds is kept and refreshed, a new condition opens one,
  and an open finding whose condition no longer holds is resolved. Measured
  conditions depend on readings expiring, so `Renga.Power.FindingSweeper`
  runs this on a clock rather than on writes.

  Findings never change the model. A supply reporting failure does not
  change structural redundancy, and an outlet drawing power with nothing
  connected opens a finding for a person rather than a connection.
  """

  import Ecto.Query, warn: false

  alias Renga.Accounts.Scope
  alias Renga.Power.Feed
  alias Renga.Power.Finding
  alias Renga.Power.Load
  alias Renga.Power.Measured
  alias Renga.Power.Outlet
  alias Renga.Power.Paths
  alias Renga.Power.Port
  alias Renga.Power.Readings
  alias Renga.Power.Redundancy
  alias Renga.Repo
  alias Renga.Topology.Cable

  @failed_supply_states ~w(failed no_input)
  @incomplete_stops [:inlet_not_connected, :inlet_unknown, :loop, :too_deep]
  # Below these an outlet's reading is noise from an idle meter, not a load.
  @draw_thresholds %{
    "real_power" => Decimal.new(5),
    "apparent_power" => Decimal.new(5),
    "current" => Decimal.new("0.05")
  }

  @doc """
  Reconciles the organization's power findings at `now`. Returns
  `{:ok, %{opened, kept, resolved}}`, or `{:ok, :busy}` when another
  reconciliation of the organization is running, which already covers it.
  """
  def reconcile(%Scope{organization_id: organization_id} = scope, now \\ Renga.Time.utc_now_ms()) do
    Repo.transaction(fn ->
      if locked?(organization_id), do: apply_conditions!(scope, now), else: :busy
    end)
  end

  defp locked?(organization_id) do
    %{rows: [[locked?]]} =
      Repo.query!("SELECT pg_try_advisory_xact_lock(hashtext('power_findings'), hashtext($1))", [
        organization_id
      ])

    locked?
  end

  defp apply_conditions!(%Scope{organization_id: organization_id} = scope, now) do
    conditions = conditions(scope, now)

    open =
      Finding
      |> where([finding], finding.organization_id == ^organization_id)
      |> where([finding], finding.status == "open")
      |> Repo.all()
      |> Map.new(&{identity(&1), &1})

    {opened, kept} =
      Enum.reduce(conditions, {0, 0}, fn condition, {opened, kept} ->
        case Map.get(open, identity(condition)) do
          nil ->
            insert!(organization_id, condition, now)
            {opened + 1, kept}

          finding ->
            refresh!(finding, condition, now)
            {opened, kept + 1}
        end
      end)

    observed = MapSet.new(conditions, &identity/1)

    resolved =
      for {identity, finding} <- open, not MapSet.member?(observed, identity) do
        finding
        |> Ecto.Changeset.change(status: "resolved", resolved_at: now)
        |> Repo.update!()
      end

    %{opened: opened, kept: kept, resolved: length(resolved)}
  end

  defp identity(%{resource_id: resource_id, kind: kind, resolution_key: key}),
    do: {resource_id, kind, key}

  defp insert!(organization_id, condition, now) do
    Repo.insert!(%Finding{
      organization_id: organization_id,
      resource_id: condition.resource_id,
      kind: condition.kind,
      resolution_key: condition.resolution_key,
      message: condition.message,
      details: condition.details,
      last_observed_at: now
    })
  end

  defp refresh!(finding, condition, now) do
    finding
    |> Ecto.Changeset.change(
      message: condition.message,
      details: condition.details,
      last_observed_at: now
    )
    |> Repo.update!()
  end

  @doc "The power conditions that hold at `now`, as finding attributes."
  def conditions(%Scope{organization_id: organization_id} = scope, now) do
    feeds = Feed |> where([feed], feed.organization_id == ^organization_id) |> Repo.all()
    ports = current(Port, organization_id)
    outlets = current(Outlet, organization_id)
    paths = Paths.for_ports(scope, ports)

    # Every resource some reading is about, modeled power endpoints or not:
    # a supply's failure needs no port to be one.
    readings = Readings.for_resources(scope, :all, now)

    capacity_conditions(scope, feeds, now) ++
      redundancy_conditions(paths) ++
      path_conditions(paths) ++
      supply_conditions(readings) ++
      draw_conditions(organization_id, outlets, readings)
  end

  defp current(schema, organization_id) do
    schema
    |> where([row], row.organization_id == ^organization_id and is_nil(row.retired_at))
    |> Repo.all()
  end

  defp capacity_conditions(_scope, [], _now), do: []

  defp capacity_conditions(scope, feeds, now) do
    loads = Load.for_feeds(scope, feeds)
    measured = Measured.for_feeds(scope, feeds, now)

    Enum.flat_map(feeds, fn feed ->
      [
        {"allocated", Map.fetch!(loads, feed.id)},
        {"measured", Map.fetch!(measured, feed.id)}
      ]
      |> Enum.filter(fn {_basis, load} -> load.status == :over end)
      |> Enum.map(fn {basis, load} ->
        %{
          resource_id: feed.resource_id,
          kind: "feed_near_capacity",
          resolution_key: basis,
          message: "#{String.capitalize(basis)} load is over #{feed.name}'s limit.",
          details: %{
            "feed_id" => feed.id,
            "basis" => basis,
            "known" => decimal(load.known),
            "usable" => decimal(load.capacity.usable),
            "unit" => Atom.to_string(load.capacity.unit),
            "legs_over" => legs_over(load.legs)
          }
        }
      end)
    end)
  end

  defp legs_over(legs) do
    for %{leg: leg, current: current, limit: limit} <- legs,
        current && Decimal.gt?(current, limit),
        do: leg
  end

  defp redundancy_conditions(paths) do
    paths
    |> Enum.group_by(& &1.port.resource_id)
    |> Enum.flat_map(fn {resource_id, device_paths} ->
      redundancy = Redundancy.of(device_paths)

      # A device with one port cannot be redundant, and one with no port
      # reaching any feed has no recorded power to judge yet; neither is a
      # finding.
      if length(device_paths) > 1 and redundancy.status == :not_redundant and
           redundancy.feeds != [] do
        [
          %{
            resource_id: resource_id,
            kind: "not_redundant",
            resolution_key: "",
            message: not_redundant_message(redundancy),
            details: %{
              "sides" => redundancy.sides,
              "feed_ids" => Enum.map(redundancy.feeds, & &1.id),
              "unfed_ports" => Enum.map(redundancy.unfed, & &1.name)
            }
          }
        ]
      else
        []
      end
    end)
  end

  defp not_redundant_message(%Redundancy{sides: []}),
    do: "Its power ports do not reach feeds on two sides."

  defp not_redundant_message(%Redundancy{sides: sides}),
    do:
      "Its power ports reach only side #{Enum.map_join(sides, " and ", &String.upcase/1)}, " <>
        "not two sides."

  defp path_conditions(paths) do
    for path <- paths, path.stop in @incomplete_stops do
      %{
        resource_id: path.port.resource_id,
        kind: "path_incomplete",
        resolution_key: path.port.id,
        message: "#{path.port.name}'s power path #{stop_phrase(path.stop)}.",
        details: %{
          "port_id" => path.port.id,
          "port" => path.port.name,
          "stop" => Atom.to_string(path.stop),
          "outlet_ids" => Enum.map(path.outlets, & &1.id)
        }
      }
    end
  end

  defp stop_phrase(:inlet_not_connected), do: "stops at a PDU whose inlet has no feed"

  defp stop_phrase(:inlet_unknown),
    do: "stops at an outlet whose hardware type does not name its inlet"

  defp stop_phrase(:loop), do: "loops back on itself"
  defp stop_phrase(:too_deep), do: "is longer than any real power train"

  # One finding per failed supply, however many of its eligible readings
  # (other windows or sources) report the failure; the latest is its evidence.
  defp supply_conditions(readings) do
    failing =
      for {resource_id, entries} <- readings,
          %{eligible?: true, reading: reading} <- entries,
          reading.boundary == "supply_input" and reading.quantity == "state",
          reading.state in @failed_supply_states,
          do: {resource_id, reading}

    for {{resource_id, supply}, readings} <-
          Enum.group_by(
            failing,
            fn {resource_id, reading} ->
              {resource_id, reading.component_name || reading.sensor}
            end,
            fn {_resource_id, reading} -> reading end
          ) do
      reading = Enum.max_by(readings, &{DateTime.to_unix(&1.event_at, :millisecond), &1.id})

      %{
        resource_id: resource_id,
        kind: "supply_failed",
        resolution_key: supply,
        message: "Power supply #{supply} reports #{String.replace(reading.state, "_", " ")}.",
        details: %{
          "supply" => supply,
          "state" => reading.state,
          "reading_id" => reading.id,
          "source_id" => reading.source_id,
          "event_at" => DateTime.to_iso8601(reading.event_at)
        }
      }
    end
  end

  defp draw_conditions(_organization_id, [], _readings), do: []

  defp draw_conditions(organization_id, outlets, readings) do
    cabled =
      Cable
      |> where([cable], cable.organization_id == ^organization_id)
      |> where([cable], cable.cable_kind == "power" and not is_nil(cable.power_outlet_id))
      |> select([cable], cable.power_outlet_id)
      |> Repo.all()
      |> MapSet.new()

    for outlet <- outlets,
        not MapSet.member?(cabled, outlet.id),
        reading <- [drawing(readings, outlet)],
        reading do
      %{
        resource_id: outlet.resource_id,
        kind: "unexpected_draw",
        resolution_key: outlet.id,
        message:
          "Outlet #{outlet.name} draws #{decimal(reading.value)} #{reading.unit} with no " <>
            "connection recorded.",
        details: %{
          "outlet_id" => outlet.id,
          "outlet" => outlet.name,
          "quantity" => reading.quantity,
          "value" => decimal(reading.value),
          "unit" => reading.unit,
          "reading_id" => reading.id,
          "source_id" => reading.source_id,
          "event_at" => DateTime.to_iso8601(reading.event_at)
        }
      }
    end
  end

  # An eligible reading of the outlet showing a real load.
  defp drawing(readings, outlet) do
    readings
    |> Map.get(outlet.resource_id, [])
    |> Enum.find_value(fn %{eligible?: eligible?, reading: reading} ->
      threshold = Map.get(@draw_thresholds, reading.quantity)

      if eligible? and threshold != nil and reading.boundary == "outlet" and
           reading.component_kind == "power_outlet" and reading.component_name == outlet.name and
           Decimal.gt?(reading.value, threshold),
         do: reading
    end)
  end

  defp decimal(nil), do: nil
  defp decimal(%Decimal{} = value), do: value |> Decimal.normalize() |> Decimal.to_string(:normal)
end
