defmodule Renga.Power.Load do
  @moduledoc """
  Allocated load on power feeds (RFD 10, "Capacity and utilization").

  A feed's loads are the ports downstream of it: a port plugged straight into
  the feed, or into an outlet whose PDU's inlet is, through any number of
  PDUs. A PDU inlet passes power on rather than drawing it, so only the ports
  at the ends of the chains count, and a PDU with nothing plugged in adds
  nothing. Loads are computed from current power cables and never stored.
  When a chain cannot be followed (an outlet in use whose hardware type does
  not name its inlet, or a chain deeper than any real power train) the
  feed's load is incomplete. So is it when a port's device has outlets that
  name no inlet: that port may pass power on to them, so its allocation is
  neither counted as a load nor taken as zero.

  Units stay apart. Allocated real load is in W. AC capacity is in VA, so
  each load converts with its own power factor (`Renga.Power.PowerFactor`);
  a load with no allocation or no power factor leaves the feed's load, and
  so its headroom, unknown rather than counted as zero. Headroom that rests
  on the organization default power factor says so.

  On a three-phase feed each load sits on the leg of the outlet it reaches
  through on the PDU plugged into the feed. Each leg's current is its
  apparent load over the phase voltage (line-to-line / √3) and is checked
  against the feed's rated current at its maximum utilization, so one
  overloaded leg is reported even when the aggregate has headroom. A load
  with no leg leaves leg coverage, and the feed's status, incomplete.

  What is known always counts towards `known`, a lower bound: a feed or leg
  it already takes over its limit is over even while its load is unknown.
  """

  import Ecto.Query, warn: false

  alias Renga.Accounts.Scope
  alias Renga.Power
  alias Renga.Power.Capacity
  alias Renga.Power.Feed
  alias Renga.Power.Outlet
  alias Renga.Power.Port
  alias Renga.Power.PowerFactor
  alias Renga.Repo
  alias Renga.Topology.Cable

  # Matches `Renga.Power.Paths`: anything deeper is a data error.
  @max_hops 8
  @legs ~w(a b c)
  @sqrt3 Decimal.new("1.7320508075688772935274463415")

  defmodule Draw do
    @moduledoc "One load on a feed: a port, its allocation, and how it converts."
    defstruct [:port, :watts, :power_factor, :va, :leg]
  end

  defmodule Leg do
    @moduledoc "One leg of a three-phase feed: apparent load, current, and its limit in A."
    defstruct [:leg, :va, :current, :limit, complete?: false]
  end

  @enforce_keys [:feed, :capacity]
  defstruct [
    :feed,
    :capacity,
    :known,
    :load,
    :headroom,
    draws: [],
    unallocated: 0,
    unconverted: 0,
    unassigned_legs: 0,
    legs: [],
    uses_default?: false,
    untraced?: false,
    status: :unknown
  ]

  @type status :: :ok | :over | :unknown

  @doc """
  The allocated load on each of `feeds`, keyed by feed id. `default` is the
  organization's default power factor, or `nil` when none is set.
  """
  def for_feeds(scope, feeds, default \\ :lookup)

  def for_feeds(%Scope{}, [], _default), do: %{}

  def for_feeds(%Scope{} = scope, feeds, :lookup),
    do: for_feeds(scope, feeds, Power.default_power_factor(scope))

  def for_feeds(%Scope{organization_id: organization_id}, [%Feed{} | _] = feeds, default) do
    {draws, untraced} = walk(organization_id, feeds)

    Map.new(feeds, fn feed ->
      feed_draws =
        draws
        |> Map.get(feed.id, [])
        |> Enum.map(&draw(&1, default))
        |> Enum.sort_by(&{&1.port.resource.name, &1.port.name})

      {feed.id, summarize(feed, feed_draws, MapSet.member?(untraced, feed.id))}
    end)
  end

  defp draw({%Port{} = port, leg}, default) do
    watts = Port.allocated_draw_w(port)
    power_factor = PowerFactor.for_port(port, default)
    va = if watts && power_factor, do: PowerFactor.to_va(watts, power_factor)
    %Draw{port: port, watts: watts, power_factor: power_factor, va: va, leg: leg}
  end

  # Collects each feed's end loads as {port, leg}, hop by hop, and the
  # devices passed on the way. A frontier entry is {port, feed id, leg}. A
  # port has one current cable, so a chain from a feed cannot loop; only its
  # length needs a bound.
  defp walk(organization_id, feeds) do
    feed_ids = Enum.map(feeds, & &1.id)
    three_phase = for feed <- feeds, three_phase?(feed), into: MapSet.new(), do: feed.id

    frontier =
      Cable
      |> where([cable], cable.organization_id == ^organization_id)
      |> where([cable], cable.cable_kind == "power" and cable.power_feed_id in ^feed_ids)
      |> preload(power_port: :resource)
      |> Repo.all()
      |> Enum.map(&{&1.power_port, &1.power_feed_id, nil})

    acc = %{draws: %{}, devices: %{}, untraced: MapSet.new()}
    acc = walk(organization_id, three_phase, frontier, 0, acc)
    {acc.draws, MapSet.union(acc.untraced, untraced(organization_id, acc.devices))}
  end

  defp walk(_organization_id, _three_phase, [], _hops, acc), do: acc

  defp walk(_organization_id, _three_phase, frontier, hops, acc) when hops >= @max_hops,
    do: %{acc | untraced: Enum.into(frontier, acc.untraced, &elem(&1, 1))}

  defp walk(organization_id, three_phase, frontier, hops, acc) do
    port_ids = Enum.map(frontier, &elem(&1, 0).id)

    hop = %{
      downstream: downstream(organization_id, port_ids),
      inlets: inlets(organization_id, port_ids),
      unmapped: unmapped(organization_id, Enum.map(frontier, &elem(&1, 0).resource_id)),
      three_phase: three_phase,
      first?: hops == 0
    }

    {next, acc} = Enum.reduce(frontier, {[], acc}, &step(&1, &2, hop))
    walk(organization_id, three_phase, next, hops + 1, acc)
  end

  defp step({port, feed_id, leg}, {next, acc}, hop) do
    acc = update_in(acc.devices, &add(&1, feed_id, port.resource_id))

    case Map.get(hop.downstream, port.id) do
      # A PDU inlet with nothing plugged in passes nothing on.
      nil when is_map_key(hop.inlets, port.id) ->
        {next, acc}

      # The port may feed outlets that name no inlet: whether it draws or
      # passes power on is unknown.
      nil when is_map_key(hop.unmapped, port.resource_id) ->
        {next, update_in(acc.untraced, &MapSet.put(&1, feed_id))}

      # Nothing downstream: the port draws the power itself.
      nil ->
        {next, update_in(acc.draws, &add(&1, feed_id, {port, leg}))}

      children ->
        # The first PDU off a three-phase feed decides each load's leg.
        first? = hop.first? and MapSet.member?(hop.three_phase, feed_id)

        children =
          for {outlet, child} <- children, do: {child, feed_id, leg_of(outlet, leg, first?)}

        {children ++ next, acc}
    end
  end

  defp add(map, key, value), do: Map.update(map, key, [value], &[value | &1])

  defp leg_of(outlet, nil, true), do: outlet.feed_leg
  defp leg_of(_outlet, leg, _first?), do: leg

  # For each port that is a PDU inlet with connected outlets: those outlets
  # and the ports plugged into them.
  defp downstream(organization_id, port_ids) do
    Cable
    |> join(:inner, [cable], outlet in Outlet, on: outlet.id == cable.power_outlet_id)
    |> where([cable], cable.organization_id == ^organization_id and cable.cable_kind == "power")
    |> where([_cable, outlet], outlet.inlet_port_id in ^port_ids)
    |> preload([_cable, outlet], power_outlet: outlet, power_port: :resource)
    |> Repo.all()
    |> Enum.group_by(& &1.power_outlet.inlet_port_id, &{&1.power_outlet, &1.power_port})
  end

  # The ports among `port_ids` that feed outlets at all.
  defp inlets(organization_id, port_ids) do
    Outlet
    |> where([outlet], outlet.organization_id == ^organization_id)
    |> where([outlet], outlet.inlet_port_id in ^port_ids and is_nil(outlet.retired_at))
    |> select([outlet], {outlet.inlet_port_id, true})
    |> distinct(true)
    |> Repo.all()
    |> Map.new()
  end

  # The devices among `resource_ids` with a current outlet that names no
  # inlet.
  defp unmapped(organization_id, resource_ids) do
    Outlet
    |> where([outlet], outlet.organization_id == ^organization_id)
    |> where([outlet], outlet.resource_id in ^Enum.uniq(resource_ids))
    |> where([outlet], is_nil(outlet.inlet_port_id) and is_nil(outlet.retired_at))
    |> select([outlet], {outlet.resource_id, true})
    |> distinct(true)
    |> Repo.all()
    |> Map.new()
  end

  # Feeds that pass a device with something plugged into an outlet whose
  # inlet its hardware type does not name: that load cannot be placed on any
  # feed, so these feeds' loads are incomplete.
  defp untraced(_organization_id, devices) when devices == %{}, do: MapSet.new()

  defp untraced(organization_id, devices) do
    resource_ids = devices |> Map.values() |> List.flatten() |> Enum.uniq()

    unmapped =
      Cable
      |> join(:inner, [cable], outlet in Outlet, on: outlet.id == cable.power_outlet_id)
      |> where([cable], cable.organization_id == ^organization_id and cable.cable_kind == "power")
      |> where([_cable, outlet], outlet.resource_id in ^resource_ids)
      |> where([_cable, outlet], is_nil(outlet.inlet_port_id))
      |> select([_cable, outlet], outlet.resource_id)
      |> distinct(true)
      |> Repo.all()
      |> MapSet.new()

    for {feed_id, ids} <- devices,
        Enum.any?(ids, &MapSet.member?(unmapped, &1)),
        into: MapSet.new(),
        do: feed_id
  end

  defp summarize(feed, draws, untraced?) do
    capacity = Capacity.of(feed)
    unallocated = Enum.count(draws, &is_nil(&1.watts))
    unconverted = unconverted(draws, capacity.unit)
    unassigned_legs = if three_phase?(feed), do: Enum.count(draws, &is_nil(&1.leg)), else: 0
    complete? = not untraced? and unallocated == 0 and unconverted == 0
    known = known(draws, capacity.unit)
    load = if complete?, do: known

    %__MODULE__{
      feed: feed,
      capacity: capacity,
      draws: draws,
      known: known,
      load: load,
      headroom: load && Decimal.sub(capacity.usable, load),
      unallocated: unallocated,
      unconverted: unconverted,
      unassigned_legs: unassigned_legs,
      legs: legs(feed, draws, complete? and unassigned_legs == 0),
      uses_default?:
        capacity.unit == :va and
          Enum.any?(draws, &(&1.watts && default?(&1.power_factor))),
      untraced?: untraced?
    }
    |> put_status()
  end

  defp default?(power_factor),
    do: match?(%PowerFactor{source: :organization_default}, power_factor)

  # A DC feed needs no conversion.
  defp unconverted(_draws, :w), do: 0
  defp unconverted(draws, :va), do: Enum.count(draws, &(&1.watts && is_nil(&1.va)))

  defp known(draws, :w),
    do: draws |> Enum.map(&(&1.watts || 0)) |> Enum.sum() |> Decimal.new()

  defp known(draws, :va),
    do: Enum.reduce(draws, Decimal.new(0), &Decimal.add(&1.va || 0, &2))

  defp legs(feed, draws, complete?) do
    if three_phase?(feed) do
      phase_voltage = Decimal.div(feed.voltage, @sqrt3)
      limit = feed.amperage |> Decimal.mult(feed.max_utilization) |> Decimal.div(100)

      for leg <- @legs do
        va =
          draws
          |> Enum.filter(&(&1.leg == leg))
          |> Enum.reduce(Decimal.new(0), &Decimal.add(&1.va || 0, &2))

        %Leg{
          leg: leg,
          va: va,
          current: Decimal.div(va, phase_voltage),
          limit: limit,
          complete?: complete?
        }
      end
    else
      []
    end
  end

  # What is known is a lower bound, so it can prove a feed or leg over its
  # limit even while the rest of the load is unknown.
  defp put_status(%__MODULE__{} = load) do
    over? =
      Decimal.gt?(load.known, load.capacity.usable) or
        Enum.any?(load.legs, &Decimal.gt?(&1.current, &1.limit))

    status =
      cond do
        over? -> :over
        is_nil(load.load) or load.unassigned_legs > 0 -> :unknown
        true -> :ok
      end

    %{load | status: status}
  end

  defp three_phase?(%Feed{supply: "ac", phase: "three"}), do: true
  defp three_phase?(%Feed{}), do: false

  @doc "The share of usable capacity a known load takes, as a whole percent rounded up."
  def percent(%__MODULE__{load: nil}), do: nil

  def percent(%__MODULE__{load: load, capacity: capacity}) do
    load
    |> Decimal.mult(100)
    |> Decimal.div(capacity.usable)
    |> Decimal.round(0, :ceiling)
    |> Decimal.to_integer()
  end
end
