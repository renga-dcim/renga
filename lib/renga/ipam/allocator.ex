defmodule Renga.IPAM.Allocator do
  @moduledoc """
  Free-space arithmetic for "next free" (RFD 4, "Addressing plan and
  allocation"): the first block of a length, or the first host, inside a
  parent prefix that no known occupant touches.

  Occupants are integer intervals `{first, last}`: child prefixes, managed
  and observed hosts, and the family's non-assignable addresses. Nothing is
  enumerated, so an IPv6 parent costs the same as an IPv4 one; each
  occupant is visited once and a collision jumps the candidate past it.

  This module only computes. `Renga.IPAM` reads the occupants and records
  the result in one transaction under the organization lock, so a block
  found free here is still free when it is written.
  """

  import Bitwise

  alias Renga.IPAM.Cidr

  @doc """
  The first `length` block inside `parent` that overlaps no occupant, as a
  prefix, or `:full`. `occupants` are `{first, last}` integer intervals in
  any order; ones outside the parent are ignored.
  """
  def next_block(%Postgrex.INET{} = parent, length, occupants) when is_integer(length) do
    family = Cidr.family(parent)
    block_size = 1 <<< (Cidr.bits(family) - length)

    case first_gap(range(parent), block_size, occupants) do
      :full -> :full
      first -> Cidr.from_integer(first, family, length)
    end
  end

  @doc """
  The first assignable host inside `parent` that no occupant holds, as an
  address with the parent's length, or `:full`. The family's
  non-assignable addresses (`non_assignable/1`) are never returned.
  """
  def next_host(%Postgrex.INET{} = parent, occupants) do
    case first_gap(range(parent), 1, non_assignable(parent) ++ occupants) do
      :full -> :full
      host -> Cidr.from_integer(host, Cidr.family(parent), Cidr.length(parent))
    end
  end

  @doc """
  The addresses of `parent` no host may be given, as intervals:

    * IPv4 up to /30: the network and broadcast addresses. /31 and /32
      have neither (RFC 3021).
    * IPv6 up to /126: the Subnet-Router anycast address, the first one
      (RFC 4291). /127 and /128 have none (RFC 6164).
    * IPv6 up to /64: also the top 128 addresses, reserved for subnet
      anycast (RFC 2526).
  """
  def non_assignable(%Postgrex.INET{} = parent) do
    {first, last} = range(parent)
    length = Cidr.length(parent)

    case Cidr.family(parent) do
      :ipv4 when length <= 30 -> [{first, first}, {last, last}]
      :ipv4 -> []
      :ipv6 when length <= 64 -> [{first, first}, {last - 127, last}]
      :ipv6 when length <= 126 -> [{first, first}]
      :ipv6 -> []
    end
  end

  @doc "A prefix or host as its `{first, last}` integer interval."
  def range(%Postgrex.INET{} = inet) do
    first = Cidr.network_at(inet, Cidr.length(inet))
    {first, first + Cidr.size(inet) - 1}
  end

  # Walks occupants by start. A candidate block that an occupant overlaps
  # moves to the first aligned block after that occupant; one that ends
  # before the next occupant starts is free.
  defp first_gap({first, last}, block_size, occupants) do
    occupants
    |> Enum.filter(fn {start, stop} -> stop >= first and start <= last end)
    |> Enum.sort()
    |> Enum.reduce_while(first, fn {start, stop}, candidate ->
      cond do
        candidate + block_size - 1 > last -> {:halt, candidate}
        stop < candidate -> {:cont, candidate}
        start > candidate + block_size - 1 -> {:halt, candidate}
        true -> {:cont, align_up(stop + 1 - first, block_size) + first}
      end
    end)
    |> then(&if(&1 + block_size - 1 > last, do: :full, else: &1))
  end

  defp align_up(offset, size), do: div(offset + size - 1, size) * size
end
