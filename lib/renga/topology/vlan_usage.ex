defmodule Renga.Topology.VlanUsage do
  @moduledoc """
  How VLAN groups and VLANs are used, for the VLAN area (RFD 8, "VLANs").

  A group's usage strip shows each of its VID ranges and which VIDs in them
  hold a VLAN. A VLAN's members compare, per interface, the membership
  operators planned (desired assignments) with what collectors observe
  (current memberships). Unlike port drift, this comparison is a plain
  side-by-side of facts rather than a finding: "planned, not observed" says
  nothing was reported, not that something is wrong.
  """

  alias Renga.Topology.Ports

  @doc """
  Summarises a group's VID ranges and the `vids` used in them.

  VIDs outside every range are ignored here; reconciliation reports those as
  findings.
  """
  def strip(%{vid_ranges: ranges}, vids) do
    used = MapSet.new(vids)

    segments =
      ranges
      |> Enum.sort_by(& &1.start_vid)
      |> Enum.map(fn range ->
        in_range = Enum.filter(used, &(&1 >= range.start_vid and &1 <= range.end_vid))

        %{
          start_vid: range.start_vid,
          end_vid: range.end_vid,
          size: range.end_vid - range.start_vid + 1,
          used: Enum.sort(in_range)
        }
      end)

    %{
      segments: segments,
      capacity: segments |> Enum.map(& &1.size) |> Enum.sum(),
      used: segments |> Enum.map(&length(&1.used)) |> Enum.sum()
    }
  end

  @doc """
  Compares one VLAN's planned and observed membership per interface.

  Rows carry the interface, the planned and observed tagging (`"tagged"`,
  `"untagged"`, or `nil`), and a state: `:both`, `:tagging_differs`,
  `:planned_only`, or `:observed_only`. Differences sort first.
  """
  def members(desired, observed) do
    planned = Map.new(desired, &{&1.interface_id, &1})
    seen = Map.new(observed, &{&1.interface_id, &1})

    planned
    |> Map.keys()
    |> Enum.concat(Map.keys(seen))
    |> Enum.uniq()
    |> Enum.map(fn interface_id ->
      plan = Map.get(planned, interface_id)
      observation = Map.get(seen, interface_id)

      %{
        interface: (plan || observation).interface,
        planned: plan && plan.tagging_mode,
        observed: observation && observation.tagging_mode,
        state: state(plan, observation)
      }
    end)
    |> Enum.sort_by(
      &{&1.state == :both, &1.interface.resource.name, Ports.natural_key(&1.interface.name)}
    )
  end

  @doc "Counts members per state, with every state present."
  def member_counts(members) do
    Enum.reduce(
      members,
      %{both: 0, tagging_differs: 0, planned_only: 0, observed_only: 0},
      &Map.update!(&2, &1.state, fn n -> n + 1 end)
    )
  end

  defp state(nil, _observation), do: :observed_only
  defp state(_plan, nil), do: :planned_only
  defp state(%{tagging_mode: same}, %{tagging_mode: same}), do: :both
  defp state(_plan, _observation), do: :tagging_differs
end
