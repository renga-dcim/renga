defmodule Renga.IPAM.PrefixTree do
  @moduledoc """
  Prefix containment trees and the scale-aware view of one prefix (RFD 8,
  "Prefixes").

  Each routing table (global or a VRF) and address family has its own tree:
  families never share rows because their containment differs. How a prefix
  is shown depends on its size:

    * a container (a prefix with children), IPv4 or IPv6, is a child-space
      map whose cells are the next planning level, and "used" means
      children allocated, such as "5 of 256 /56s";
    * an IPv4 leaf with at most 1,024 addresses is a per-address map, and
      "used" is host utilization;
    * any other leaf (an IPv6 /64, a large IPv4 leaf) is an address table,
      and "used" is an address count, never a percentage.
  """

  import Bitwise

  alias Renga.IPAM.Cidr

  @address_map_limit 1024
  @max_cells 256

  @doc """
  Builds the trees for `prefixes`, keyed by `{vrf, family}`.

  Nodes are `%{prefix: prefix, children: [node]}`, ordered by network.
  """
  def build(prefixes) do
    prefixes
    |> Enum.group_by(&{&1.vrf, Cidr.family(&1.prefix)})
    |> Map.new(fn {key, group} -> {key, nest(group)} end)
  end

  @doc "Flattens a tree depth-first into `{node, depth}` pairs."
  def flatten(nodes, depth \\ 0) do
    Enum.flat_map(nodes, fn node -> [{node, depth} | flatten(node.children, depth + 1)] end)
  end

  @doc "How a prefix is shown: `:container`, `:address_map`, or `:address_table`."
  def mode(%{children: [_ | _]}), do: :container

  def mode(%{prefix: %{prefix: cidr}}) do
    if Cidr.family(cidr) == :ipv4 and Cidr.size(cidr) <= @address_map_limit,
      do: :address_map,
      else: :address_table
  end

  @doc """
  The planning level of a container: the most common length among its
  direct children, ties going to the longer prefix.
  """
  def planning_level(%{children: children}) do
    children
    |> Enum.frequencies_by(&Cidr.length(&1.prefix.prefix))
    |> Enum.max_by(fn {length, count} -> {count, length} end)
    |> elem(0)
  end

  @doc """
  The child-space map of a container.

  Cells are blocks at the planning level, or coarser blocks when that level
  would need more than #{@max_cells} cells. Each cell is `:allocated` (one
  child covers it, and the cell opens that child), `:partial` (children use
  part of it), or `:free`. `allocated` and `total` count planning-level
  blocks, for "5 of 256 /56s".
  """
  def space_map(%{prefix: %{prefix: cidr}, children: children} = node) do
    family = Cidr.family(cidr)
    bits = Cidr.bits(family)
    length = Cidr.length(cidr)
    level = planning_level(node)
    cell_length = min(level, length + 8)
    base = Cidr.network_at(cidr, length)
    cell_size = 1 <<< (bits - cell_length)

    cells =
      for index <- 0..((1 <<< (cell_length - length)) - 1) do
        network = base + index * cell_size
        cell = Cidr.from_integer(network, family, cell_length)
        cell(cell, children)
      end

    %{
      level: level,
      cell_length: cell_length,
      cells: cells,
      total: 1 <<< (level - length),
      allocated: allocated_blocks(children, level, bits)
    }
  end

  defp cell(cell, children) do
    covering = Enum.find(children, &Cidr.contains?(&1.prefix.prefix, cell))

    inside =
      if covering, do: [], else: Enum.filter(children, &Cidr.contains?(cell, &1.prefix.prefix))

    state =
      cond do
        covering -> :allocated
        inside != [] -> :partial
        true -> :free
      end

    %{cidr: cell, state: state, child: covering || List.first(inside), count: length(inside)}
  end

  # Planning-level blocks touched by any child: a short child covers several
  # blocks, and every long child inside one block counts that block once.
  defp allocated_blocks(children, level, bits) do
    children
    |> Enum.flat_map(fn child ->
      cidr = child.prefix.prefix
      child_length = Cidr.length(cidr)
      first = Cidr.network_at(cidr, min(child_length, level)) >>> (bits - level)

      if child_length >= level,
        do: [first],
        else: Enum.to_list(first..(first + (1 <<< (level - child_length)) - 1))
    end)
    |> MapSet.new()
    |> MapSet.size()
  end

  @doc """
  The per-address map of a small IPv4 leaf: one cell per address, marked
  `:network`, `:broadcast`, `:used`, or `:free`, with the hosts usable and
  used for the utilization percentage.

  /31 and /32 prefixes have no network or broadcast address (RFC 3021).
  """
  def address_map(%{prefix: %{prefix: cidr}}, addresses) do
    length = Cidr.length(cidr)
    size = Cidr.size(cidr)
    base = Cidr.network_at(cidr, length)
    used = Map.new(addresses, &{Cidr.to_integer(&1.address), &1})
    reserved? = length <= 30

    cells =
      for offset <- 0..(size - 1) do
        value = base + offset

        state = address_state(offset, size, reserved?, Map.has_key?(used, value))

        %{
          address: Cidr.from_integer(value, :ipv4, 32),
          offset: offset,
          state: state,
          record: Map.get(used, value)
        }
      end

    usable = if reserved?, do: size - 2, else: size
    used_count = Enum.count(cells, &(&1.state == :used))

    %{
      cells: cells,
      usable: usable,
      used: used_count,
      percent: if(usable > 0, do: round(used_count / usable * 100), else: 0)
    }
  end

  defp address_state(0, _size, true, _used?), do: :network
  defp address_state(offset, size, true, _used?) when offset == size - 1, do: :broadcast
  defp address_state(_offset, _size, _reserved?, true), do: :used
  defp address_state(_offset, _size, _reserved?, false), do: :free

  defp nest(prefixes) do
    prefixes
    |> Enum.sort_by(&{Cidr.to_integer(&1.prefix), Cidr.length(&1.prefix)})
    |> nest_sorted()
  end

  # Sorted by network then length, a prefix's descendants follow it
  # contiguously, so each prefix takes the run it contains as its subtree.
  defp nest_sorted([]), do: []

  defp nest_sorted([first | rest]) do
    {inside, outside} = Enum.split_while(rest, &Cidr.contains?(first.prefix, &1.prefix))
    [%{prefix: first, children: nest_sorted(inside)} | nest_sorted(outside)]
  end
end
