defmodule Renga.Power.Paths do
  @moduledoc """
  A device's power paths (RFD 10, "Power path"): from each power port through
  the outlet it is plugged into, that outlet's PDU and inlet, and onwards
  until a panel feed. Paths are computed from current power cables and never
  stored.

  A path that does not reach a feed says where it stops:

    * `:not_connected` - the device's own port has no current cable.
    * `:inlet_unknown` - an outlet's hardware type does not name the inlet
      that feeds it.
    * `:inlet_not_connected` - a PDU's inlet has no current cable.
    * `:loop` - the chain comes back to a port it already passed.
    * `:too_deep` - the chain is longer than any real power train.
  """

  import Ecto.Query, warn: false

  alias Renga.Accounts.Scope
  alias Renga.Power.Port
  alias Renga.Power.Paths.Path
  alias Renga.Repo
  alias Renga.Topology.Cable

  # Server to rack PDU to floor PDU to feed is three hops; anything far
  # beyond that is a data error rather than a power train.
  @max_hops 8

  @doc "The power path of each of `ports`, in the same order."
  def for_ports(%Scope{}, []), do: []

  def for_ports(%Scope{organization_id: organization_id}, [%Port{} | _] = ports) do
    paths = Map.new(ports, &{&1.id, %Path{port: &1}})
    frontier = Map.new(ports, &{{&1.id, &1.id}, {&1.id, MapSet.new([&1.id])}})
    paths = walk(organization_id, paths, frontier, 0)
    Enum.map(ports, &Map.fetch!(paths, &1.id))
  end

  # `frontier` maps {port to follow next, path it extends} to that path and
  # the ports it has already passed. Two paths can meet at one PDU inlet, so
  # the port alone is not a key.
  defp walk(_organization_id, paths, frontier, _hops) when frontier == %{}, do: paths

  defp walk(_organization_id, paths, frontier, hops) when hops >= @max_hops do
    Enum.reduce(frontier, paths, fn {_key, {path_id, _seen}}, paths ->
      stop(paths, path_id, :too_deep)
    end)
  end

  defp walk(organization_id, paths, frontier, hops) do
    cables = cables_by_port(organization_id, Map.keys(frontier))

    {paths, next} =
      Enum.reduce(frontier, {paths, %{}}, fn {key, {path_id, seen}}, acc ->
        step(acc, Map.get(cables, key), path_id, seen, hops)
      end)

    walk(organization_id, paths, next, hops + 1)
  end

  defp step({paths, next}, nil, path_id, _seen, hops) do
    reason = if hops == 0, do: :not_connected, else: :inlet_not_connected
    {stop(paths, path_id, reason), next}
  end

  defp step({paths, next}, %Cable{power_feed: %{} = feed}, path_id, _seen, _hops),
    do: {Map.update!(paths, path_id, &%{&1 | feed: feed}), next}

  defp step({paths, next}, %Cable{power_outlet: outlet}, path_id, seen, _hops) do
    paths = Map.update!(paths, path_id, &%{&1 | outlets: &1.outlets ++ [outlet]})
    follow_inlet(paths, next, path_id, seen, outlet.inlet_port_id)
  end

  defp follow_inlet(paths, next, path_id, _seen, nil),
    do: {stop(paths, path_id, :inlet_unknown), next}

  defp follow_inlet(paths, next, path_id, seen, inlet_id) do
    if MapSet.member?(seen, inlet_id) do
      {stop(paths, path_id, :loop), next}
    else
      {paths, Map.put(next, {inlet_id, path_id}, {path_id, MapSet.put(seen, inlet_id)})}
    end
  end

  defp stop(paths, path_id, reason), do: Map.update!(paths, path_id, &%{&1 | stop: reason})

  defp cables_by_port(organization_id, keys) do
    port_ids = keys |> Enum.map(&elem(&1, 0)) |> Enum.uniq()

    cables =
      Cable
      |> where([cable], cable.organization_id == ^organization_id)
      |> where([cable], cable.cable_kind == "power" and cable.power_port_id in ^port_ids)
      |> preload(power_outlet: [:resource, :inlet_port], power_feed: :panel)
      |> Repo.all()
      |> Map.new(&{&1.power_port_id, &1})

    Map.new(keys, &{&1, Map.get(cables, elem(&1, 0))})
  end
end
