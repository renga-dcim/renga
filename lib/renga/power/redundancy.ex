defmodule Renga.Power.Redundancy do
  @moduledoc """
  Structural power redundancy (RFD 10, "Power path"): a device is redundantly
  powered when its ports reach feeds on at least two sides. Two supplies both
  on side `a` are not redundant, whatever the supply count says, and a feed
  with no side cannot make a device redundant.

  A path that cannot be traced (an outlet whose hardware type does not name
  its inlet, or a chain deeper than any power train) may reach any feed, so
  a device that is not already redundant through its traced paths has
  `:unknown` redundancy rather than `:not_redundant`.

  It is computed from recorded power paths only. Live supply state from
  readings is separate evidence and never changes it.

  `feed_failure/2` answers "what fails if this feed fails": the devices below
  the feed, PDUs included, that lose all of their supply, those that keep
  supply but lose their redundancy, and those that might, because a path
  that cannot be traced may or may not reach another feed.
  """

  import Ecto.Query, warn: false

  alias Renga.Accounts.Scope
  alias Renga.Power.Feed
  alias Renga.Power.Load
  alias Renga.Power.Paths
  alias Renga.Power.Port
  alias Renga.Repo
  alias Renga.Topology.Cable

  @type status :: :redundant | :not_redundant | :unknown | :single_supply | :none

  # Stops that leave a path's feed unknown, rather than show it has none.
  @untraced_stops [:inlet_unknown, :too_deep]

  defstruct status: :none, sides: [], feeds: [], unfed: [], sideless: [], untraced: []

  @doc """
  The redundancy of a device from its ports' power paths: the sides its
  ports reach, the feeds, the ports that reach no feed, the ports whose
  path cannot be traced, and the feeds with no side.
  """
  def of(paths) do
    feeds = paths |> Enum.map(& &1.feed) |> Enum.reject(&is_nil/1) |> Enum.uniq_by(& &1.id)
    sides = feeds |> Enum.map(& &1.side) |> Enum.reject(&is_nil/1) |> Enum.uniq() |> Enum.sort()
    untraced = for path <- paths, untraced?(path), do: path.port

    status =
      cond do
        paths == [] -> :none
        match?([_], paths) -> :single_supply
        match?([_, _ | _], sides) -> :redundant
        untraced != [] -> :unknown
        true -> :not_redundant
      end

    %__MODULE__{
      status: status,
      sides: sides,
      feeds: Enum.sort_by(feeds, & &1.name),
      unfed: for(path <- paths, is_nil(path.feed) and not untraced?(path), do: path.port),
      untraced: untraced,
      sideless: Enum.filter(feeds, &is_nil(&1.side))
    }
  end

  defp untraced?(path), do: path.stop in @untraced_stops

  defmodule Failure do
    @moduledoc """
    What fails with one feed. Each entry is `{resource, remaining}`, the
    feeds the device still reaches. An `uncertain` entry is
    `{resource, remaining, consequence}`: the device loses all supply
    (`:supply`) or its redundancy (`:redundancy`) unless a path that cannot
    be traced reaches another feed. `untraced?` is set when part of the
    chain below the feed cannot be followed, so devices there are missing.
    """
    defstruct [
      :feed,
      loses_supply: [],
      loses_redundancy: [],
      uncertain: [],
      keeps: 0,
      untraced?: false
    ]
  end

  @doc """
  The devices below `feed`, PDUs included, that lose all supply or their
  redundancy if it fails, and those that might.
  """
  def feed_failure(%Scope{} = scope, %Feed{} = feed) do
    # Every device the walk passes, PDUs and empty ones included.
    load = scope |> Load.for_feeds([feed], nil) |> Map.fetch!(feed.id)

    devices =
      scope
      |> ports(load.devices)
      |> then(&Paths.for_ports(scope, &1))
      |> Enum.group_by(& &1.port.resource_id)
      |> Enum.map(fn {_id, [path | _] = paths} -> classify(path.port.resource, paths, feed) end)
      |> Enum.sort_by(fn {_kind, entry} -> elem(entry, 0).name end)

    of_kind = fn kind -> for {^kind, entry} <- devices, do: entry end

    %Failure{
      feed: feed,
      loses_supply: of_kind.(:loses_supply),
      loses_redundancy: of_kind.(:loses_redundancy),
      uncertain: of_kind.(:uncertain),
      keeps: length(of_kind.(:keeps)),
      untraced?: load.untraced?
    }
  end

  defp classify(resource, paths, feed) do
    survivors = Enum.filter(paths, &(&1.feed && &1.feed.id != feed.id))
    remaining = of(survivors).feeds

    case consequence(paths, survivors, feed) do
      nil -> {:keeps, {resource, remaining}}
      {kind, true} -> {:uncertain, {resource, remaining, kind}}
      {:supply, false} -> {:loses_supply, {resource, remaining}}
      {:redundancy, false} -> {:loses_redundancy, {resource, remaining}}
    end
  end

  # What the device loses if `feed` fails, and whether that rests on paths
  # that cannot be traced.
  defp consequence(paths, survivors, feed) do
    untraced? = Enum.any?(paths, &untraced?/1)

    cond do
      survivors == [] ->
        {:supply, untraced?}

      untraced? and may_lose_redundancy?(paths, survivors, feed) ->
        {:redundancy, true}

      of(paths).status == :redundant and of(survivors).status != :redundant ->
        {:redundancy, false}

      true ->
        nil
    end
  end

  # With paths that cannot be traced, each may reach any feed. The device
  # may have been redundant and not be once `feed` fails only when its
  # survivors trace fewer than two sides, and either its traced paths
  # already reached two sides, or no survivor traces a side and the failed
  # feed has one: an untraced path on the other side would have made it
  # redundant and leave it on one side. In any other case an untraced path
  # that made it redundant still does afterwards.
  defp may_lose_redundancy?(paths, survivors, feed) do
    survivor_sides = of(survivors).sides

    length(survivor_sides) < 2 and
      (match?([_, _ | _], of(paths).sides) or (survivor_sides == [] and not is_nil(feed.side)))
  end

  # A device's ports from its hardware type, and any port retired from it
  # that still has a current power cable: it still draws power.
  defp ports(_scope, []), do: []

  defp ports(%Scope{organization_id: organization_id}, resource_ids) do
    cabled =
      from cable in Cable,
        where: cable.organization_id == ^organization_id and cable.cable_kind == "power",
        select: cable.power_port_id

    Port
    |> where([port], port.organization_id == ^organization_id)
    |> where([port], port.resource_id in ^resource_ids)
    |> where([port], is_nil(port.retired_at) or port.id in subquery(cabled))
    |> order_by([port], port.name)
    |> preload(:resource)
    |> Repo.all()
  end
end
