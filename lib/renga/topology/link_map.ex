defmodule Renga.Topology.LinkMap do
  @moduledoc """
  Arranges links into a device map for the topology page (RFD 8).

  Devices are laid out in tiers: spine switches (switches whose links all
  lead to other switches), leaf switches, then every other device. Within a
  tier, devices sit under the devices they connect to above (a barycenter
  ordering), which keeps most lines short and uncrossed without a layout
  engine. Links between the same two devices share one edge whose state is
  the most urgent of its links, so a bundle of agreeing links with one
  disagreement still draws attention.

  The map draws at most `:max_nodes` devices, keeping switches and the most
  connected devices; the link table below the map still lists every link.
  """

  alias Renga.Topology.Links

  @default_max_nodes 60
  @network_kinds ~w(switch)

  defstruct tiers: [], edges: [], hidden: 0

  @doc """
  Builds the map for `links`.

  Options:

    * `:max_nodes` - devices drawn at most (default #{@default_max_nodes});
    * `:focus` - a resource id that is always drawn.
  """
  def build(links, opts \\ []) do
    max_nodes = Keyword.get(opts, :max_nodes, @default_max_nodes)
    edges = edges(links)
    resources = resources(edges)
    drawn = drawn_ids(resources, edges, max_nodes, Keyword.get(opts, :focus))
    edges = Enum.filter(edges, &(MapSet.member?(drawn, &1.a) and MapSet.member?(drawn, &1.b)))
    neighbors = neighbors(edges)

    %__MODULE__{
      tiers: tiers(Map.take(resources, MapSet.to_list(drawn)), neighbors),
      edges: edges,
      hidden: map_size(resources) - MapSet.size(drawn)
    }
  end

  # One edge per device pair. A cable looped between two ports of the same
  # device has no edge to draw; the link table still lists it.
  defp edges(links) do
    links
    |> Enum.reject(&(&1.interface_a.resource_id == &1.interface_b.resource_id))
    |> Enum.group_by(&resource_pair/1)
    |> Enum.map(fn {{a, b}, links} ->
      links = Enum.sort_by(links, &Links.severity(&1.state))
      [primary | _rest] = links

      %{
        id: "#{a}_#{b}",
        a: a,
        b: b,
        resource_a: resource_for(primary, a),
        resource_b: resource_for(primary, b),
        state: primary.state,
        link_keys: Enum.map(links, & &1.key),
        primary: primary.key
      }
    end)
    |> Enum.sort_by(&{Links.severity(&1.state), &1.id})
  end

  defp resource_pair(link) do
    a = link.interface_a.resource_id
    b = link.interface_b.resource_id
    if a <= b, do: {a, b}, else: {b, a}
  end

  defp resource_for(link, id) do
    if link.interface_a.resource_id == id,
      do: link.interface_a.resource,
      else: link.interface_b.resource
  end

  defp resources(edges) do
    Enum.reduce(edges, %{}, fn edge, acc ->
      acc |> Map.put(edge.a, edge.resource_a) |> Map.put(edge.b, edge.resource_b)
    end)
  end

  defp neighbors(edges) do
    Enum.reduce(edges, %{}, fn edge, acc ->
      acc
      |> Map.update(edge.a, [edge.b], &[edge.b | &1])
      |> Map.update(edge.b, [edge.a], &[edge.a | &1])
    end)
  end

  # Switches carry the structure of the network, so they are kept before
  # hosts; among each, the most connected devices say the most.
  defp drawn_ids(resources, edges, max_nodes, focus) do
    degrees = edges |> neighbors() |> Map.new(fn {id, ids} -> {id, length(ids)} end)

    ranked =
      resources
      |> Map.values()
      |> Enum.sort_by(&{&1.id != focus, not network?(&1), -Map.get(degrees, &1.id, 0), &1.name})
      |> Enum.take(max_nodes)

    MapSet.new(ranked, & &1.id)
  end

  defp tiers(resources, neighbors) do
    {network, devices} = resources |> Map.values() |> Enum.split_with(&network?/1)
    kind_of = Map.new(resources, fn {id, resource} -> {id, resource.kind} end)

    {spines, leaves} =
      Enum.split_with(network, fn switch ->
        neighbors
        |> Map.get(switch.id, [])
        |> Enum.all?(&(Map.get(kind_of, &1) in @network_kinds))
      end)

    switch_tiers =
      if spines == [] or leaves == [],
        do: [{:switches, "Switches", spines ++ leaves}],
        else: [{:spine, "Spine switches", spines}, {:leaf, "Leaf switches", leaves}]

    (switch_tiers ++ [{:devices, "Devices", devices}])
    |> Enum.reject(fn {_id, _label, nodes} -> nodes == [] end)
    |> order_tiers(neighbors)
  end

  # The first tier is alphabetical; each later tier is ordered by where its
  # devices' neighbors sit in the tiers above, as a fraction of each tier's
  # width so tiers of different sizes compare.
  defp order_tiers(tiers, neighbors) do
    {ordered, _positions} =
      Enum.map_reduce(tiers, %{}, fn {id, label, nodes}, positions ->
        nodes = Enum.sort_by(nodes, &{barycenter(&1.id, neighbors, positions), &1.name})
        count = length(nodes)

        positions =
          nodes
          |> Enum.with_index()
          |> Enum.reduce(positions, fn {node, index}, acc ->
            Map.put(acc, node.id, (index + 0.5) / count)
          end)

        {%{id: id, label: label, nodes: nodes}, positions}
      end)

    ordered
  end

  # Devices with no neighbor above sort after those that have one.
  defp barycenter(id, neighbors, positions) do
    case neighbors |> Map.get(id, []) |> Enum.flat_map(&List.wrap(Map.get(positions, &1))) do
      [] -> 2.0
      above -> Enum.sum(above) / length(above)
    end
  end

  defp network?(resource), do: resource.kind in @network_kinds
end
