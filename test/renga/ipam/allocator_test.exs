defmodule Renga.IPAM.AllocatorTest do
  @moduledoc """
  Free-space arithmetic for "next free" (RFD 4, "Addressing plan and
  allocation"): aligned blocks and hosts that no occupant touches, found
  without enumerating the space, with each family's non-assignable
  addresses left out.
  """
  use ExUnit.Case, async: true

  alias Renga.IPAM.Allocator
  alias Renga.IPAM.Cidr

  defp cidr(text) do
    {:ok, inet} = Renga.Types.Cidr.cast(text)
    inet
  end

  defp occupying(texts), do: Enum.map(texts, &Allocator.range(cidr(&1)))

  test "the first aligned block that no occupant overlaps" do
    parent = cidr("10.0.0.0/16")

    assert Cidr.format(Allocator.next_block(parent, 24, [])) == "10.0.0.0/24"

    # A child, a host inside the next block, and a wider child each push
    # the candidate past them to the next aligned block.
    occupants = occupying(["10.0.0.0/24", "10.0.1.77/32", "10.0.2.0/23", "10.0.5.0/25"])
    assert Cidr.format(Allocator.next_block(parent, 24, occupants)) == "10.0.4.0/24"
    # A host fills only the half of 10.0.1.0/24 it is in.
    assert Cidr.format(Allocator.next_block(parent, 25, occupants)) == "10.0.1.128/25"
    assert Cidr.format(Allocator.next_block(parent, 22, occupants)) == "10.0.8.0/22"

    # Occupants outside the parent, in any order, change nothing.
    assert Cidr.format(Allocator.next_block(parent, 24, occupying(["10.1.0.0/24", "9.0.0.0/8"]))) ==
             "10.0.0.0/24"

    assert Allocator.next_block(
             cidr("10.0.0.0/24"),
             25,
             occupying(["10.0.0.0/25", "10.0.0.200/32"])
           ) ==
             :full
  end

  test "IPv6 blocks are found by arithmetic, not by enumeration" do
    parent = cidr("2001:db8::/32")

    # Every /48 of the first half is taken by one /33; the next free /64 is
    # the first of the second half.
    occupants = occupying(["2001:db8::/33"])
    assert Cidr.format(Allocator.next_block(parent, 64, occupants)) == "2001:db8:8000::/64"

    assert Cidr.format(Allocator.next_block(parent, 56, occupying(["2001:db8::1/128"]))) ==
             "2001:db8:0:100::/56"
  end

  test "the first assignable host skips each family's non-assignable addresses" do
    # IPv4: network and broadcast are never hosts, except in /31 and /32.
    assert Cidr.format(Allocator.next_host(cidr("192.0.2.0/24"), [])) == "192.0.2.1/24"

    assert Cidr.format(
             Allocator.next_host(
               cidr("192.0.2.0/24"),
               occupying(["192.0.2.1/32", "192.0.2.2/32"])
             )
           ) == "192.0.2.3/24"

    assert Allocator.next_host(cidr("192.0.2.0/30"), occupying(["192.0.2.1/32", "192.0.2.2/32"])) ==
             :full

    assert Cidr.format(Allocator.next_host(cidr("192.0.2.0/31"), [])) == "192.0.2.0/31"

    # IPv6: skip Subnet-Router anycast and the registered subnet-anycast IIDs.
    assert Cidr.format(Allocator.next_host(cidr("2001:db8::/64"), [])) == "2001:db8::1/64"
    assert Cidr.format(Allocator.next_host(cidr("2001:db8::/127"), [])) == "2001:db8::/127"

    assert [_, reserved] = Allocator.non_assignable(cidr("2001:db8::/64"))
    assert reserved == Allocator.range(cidr("2001:db8::fdff:ffff:ffff:ff80/121"))
  end

  test "IPv6 subnet-anycast IIDs are skipped in narrow and multi-subnet parents" do
    for parent <- ["2001:db8::/64", "2001:db8::/63"] do
      {first, _} = Allocator.range(cidr(parent))
      {reserved_first, _} = Allocator.range(cidr("2001:db8::fdff:ffff:ffff:ff80/121"))

      assert Cidr.format(Allocator.next_host(cidr(parent), [{first, reserved_first - 1}])) ==
               "2001:db8:0:0:fe00::/#{Cidr.length(cidr(parent))}"
    end

    # An occupant jumps into the reservation of a later /64 without enumerating subnets.
    {first, _} = Allocator.range(cidr("2001:db8::/32"))
    {reserved_first, _} = Allocator.range(cidr("2001:db8:abcd:1234:fdff:ffff:ffff:ff80/121"))

    assert Cidr.format(Allocator.next_host(cidr("2001:db8::/32"), [{first, reserved_first - 1}])) ==
             "2001:db8:abcd:1234:fe00::/32"

    assert Allocator.next_host(cidr("2001:db8::fdff:ffff:ffff:ff80/121"), []) == :full
    assert Allocator.next_host(cidr("2001:db8::fdff:ffff:ffff:fffe/127"), []) == :full

    assert Cidr.format(Allocator.next_host(cidr("2001:db8::ffff:ffff:ffff:ff80/121"), [])) ==
             "2001:db8::ffff:ffff:ffff:ff81/121"
  end
end
