defmodule Renga.Power.Redundancy do
  @moduledoc """
  Structural power redundancy (RFD 10, "Power path"): a device is redundantly
  powered when its ports reach feeds on at least two sides. Two supplies both
  on side `a` are not redundant, whatever the supply count says, and a feed
  with no side cannot make a device redundant.

  It is computed from recorded power paths only. Live supply state from
  readings is separate evidence and never changes it.

  `feed_failure/2` answers "what fails if this feed fails": the devices below
  the feed that lose all of their supply, and those that keep supply but lose
  their redundancy.
  """

  import Ecto.Query, warn: false

  alias Renga.Accounts.Scope
  alias Renga.Power.Feed
  alias Renga.Power.Load
  alias Renga.Power.Paths
  alias Renga.Power.Port
  alias Renga.Repo

  @type status :: :redundant | :not_redundant | :single_supply | :none

  defstruct status: :none, sides: [], feeds: [], unfed: [], sideless: []

  @doc """
  The redundancy of a device from its ports' power paths: the sides its
  ports reach, the feeds, the ports that reach no feed, and the feeds with
  no side.
  """
  def of(paths) do
    feeds = paths |> Enum.map(& &1.feed) |> Enum.reject(&is_nil/1) |> Enum.uniq_by(& &1.id)
    sides = feeds |> Enum.map(& &1.side) |> Enum.reject(&is_nil/1) |> Enum.uniq() |> Enum.sort()

    status =
      cond do
        paths == [] -> :none
        match?([_], paths) -> :single_supply
        match?([_, _ | _], sides) -> :redundant
        true -> :not_redundant
      end

    %__MODULE__{
      status: status,
      sides: sides,
      feeds: Enum.sort_by(feeds, & &1.name),
      unfed: for(path <- paths, is_nil(path.feed), do: path.port),
      sideless: Enum.filter(feeds, &is_nil(&1.side))
    }
  end

  defmodule Failure do
    @moduledoc """
    What fails with one feed. Each entry is `{resource, remaining}`, the
    feeds the device still reaches. `untraced?` is set when part of the chain
    below the feed cannot be followed, so devices there are missing.
    """
    defstruct [:feed, loses_supply: [], loses_redundancy: [], keeps: 0, untraced?: false]
  end

  @doc "The devices below `feed` that lose all supply or their redundancy if it fails."
  def feed_failure(%Scope{} = scope, %Feed{} = feed) do
    load = scope |> Load.for_feeds([feed], nil) |> Map.fetch!(feed.id)
    resource_ids = load.draws |> Enum.map(& &1.port.resource_id) |> Enum.uniq()

    devices =
      scope
      |> ports(resource_ids)
      |> then(&Paths.for_ports(scope, &1))
      |> Enum.group_by(& &1.port.resource)
      |> Enum.map(fn {resource, paths} -> {resource, paths, survivors(paths, feed)} end)
      |> Enum.sort_by(fn {resource, _paths, _survivors} -> resource.name end)

    {loses_supply, rest} =
      Enum.split_with(devices, fn {_resource, _paths, survivors} -> survivors == [] end)

    loses_redundancy =
      Enum.filter(rest, fn {_resource, paths, survivors} ->
        of(paths).status == :redundant and of(survivors).status != :redundant
      end)

    %Failure{
      feed: feed,
      loses_supply: Enum.map(loses_supply, &entry/1),
      loses_redundancy: Enum.map(loses_redundancy, &entry/1),
      keeps: length(devices) - length(loses_supply) - length(loses_redundancy),
      untraced?: load.untraced?
    }
  end

  # The paths that still reach a feed once `feed` is gone.
  defp survivors(paths, feed), do: Enum.filter(paths, &(&1.feed && &1.feed.id != feed.id))

  defp entry({resource, _paths, survivors}), do: {resource, of(survivors).feeds}

  defp ports(_scope, []), do: []

  defp ports(%Scope{organization_id: organization_id}, resource_ids) do
    Port
    |> where([port], port.organization_id == ^organization_id)
    |> where([port], port.resource_id in ^resource_ids and is_nil(port.retired_at))
    |> order_by([port], port.name)
    |> preload(:resource)
    |> Repo.all()
  end
end
