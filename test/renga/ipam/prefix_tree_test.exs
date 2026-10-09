defmodule Renga.IPAM.PrefixTreeTest do
  use ExUnit.Case, async: true

  alias Renga.IPAM.AddressAssignment
  alias Renga.IPAM.Cidr
  alias Renga.IPAM.PrefixTree

  defp cidr(text) do
    {:ok, inet} = Renga.Types.Cidr.cast(text)
    inet
  end

  defp prefix(text, vrf_id \\ nil), do: %{id: text, prefix: cidr(text), vrf_id: vrf_id}

  defp address(text, metadata \\ %{}) do
    {:ok, inet} = Renga.Types.Inet.cast(text)
    %{address: inet, metadata: metadata}
  end

  describe "Cidr" do
    test "does integer arithmetic for both families" do
      assert Cidr.size(cidr("10.0.0.0/24")) == 256
      assert Cidr.size(cidr("2001:db8::/64")) == 18_446_744_073_709_551_616
      assert Cidr.contains?(cidr("10.0.0.0/16"), cidr("10.0.4.0/24"))
      refute Cidr.contains?(cidr("10.0.4.0/24"), cidr("10.0.0.0/16"))
      refute Cidr.contains?(cidr("10.0.0.0/8"), cidr("2001:db8::/32"))

      assert Cidr.format(Cidr.from_integer(Cidr.to_integer(cidr("2001:db8:a::/48")), :ipv6, 48)) ==
               "2001:db8:a::/48"
    end

    test "splits an IPv6 address at the groups its prefix covers" do
      {:ok, inet} = Renga.Types.Inet.cast("2001:db8:a:10:0:0:0:15")
      assert Cidr.split_ipv6(inet, 64) == {"2001:db8:a:10", "::15"}

      {:ok, eui} = Renga.Types.Inet.cast("2001:db8:a:10:21b:21ff:fe3c:4d5e")
      assert Cidr.split_ipv6(eui, 64) == {"2001:db8:a:10:", "21b:21ff:fe3c:4d5e"}

      {head, tail} = Cidr.split_ipv6(inet, 128)
      assert {:ok, parsed} = :inet.parse_address(String.to_charlist(head <> tail))
      assert parsed == inet.address
    end
  end

  describe "build/1" do
    test "never nests a prefix under an exact duplicate of itself" do
      trees =
        PrefixTree.build([prefix("10.0.0.0/24"), prefix("10.0.0.0/24"), prefix("10.0.0.0/25")])

      [first, second] = trees[{nil, :ipv4}]

      assert {first.children, length(second.children)} == {[], 1}
    end

    test "nests prefixes per routing table and family" do
      trees =
        PrefixTree.build([
          prefix("10.0.1.0/24"),
          prefix("10.0.0.0/16"),
          prefix("10.0.0.0/24"),
          prefix("10.0.0.128/25"),
          prefix("192.168.0.0/24"),
          prefix("2001:db8::/32"),
          prefix("10.0.0.0/16", "blue")
        ])

      assert [{_, 0}, {_, 1}, {_, 2}, {_, 1}, {_, 0}] = PrefixTree.flatten(trees[{nil, :ipv4}])

      assert Enum.map(PrefixTree.flatten(trees[{nil, :ipv4}]), fn {node, depth} ->
               {node.prefix.id, depth}
             end) == [
               {"10.0.0.0/16", 0},
               {"10.0.0.0/24", 1},
               {"10.0.0.128/25", 2},
               {"10.0.1.0/24", 1},
               {"192.168.0.0/24", 0}
             ]

      assert [%{prefix: %{id: "2001:db8::/32"}}] = trees[{nil, :ipv6}]
      assert [%{prefix: %{vrf_id: "blue"}}] = trees[{"blue", :ipv4}]
    end
  end

  describe "views by size" do
    test "chooses a container map, an address map, or an address table" do
      [container] = PrefixTree.build([prefix("10.0.0.0/16"), prefix("10.0.0.0/24")])[{nil, :ipv4}]
      [small] = PrefixTree.build([prefix("10.0.0.0/22")])[{nil, :ipv4}]
      [large] = PrefixTree.build([prefix("10.0.0.0/21")])[{nil, :ipv4}]
      [v6] = PrefixTree.build([prefix("2001:db8::/64")])[{nil, :ipv6}]

      assert PrefixTree.mode(container) == :container
      assert PrefixTree.mode(small) == :address_map
      assert PrefixTree.mode(large) == :address_table
      assert PrefixTree.mode(v6) == :address_table
    end

    test "maps a container's child space at its planning level" do
      [node] =
        PrefixTree.build([
          prefix("2001:db8:a::/48"),
          prefix("2001:db8:a::/56"),
          prefix("2001:db8:a:100::/56"),
          prefix("2001:db8:a:500::/56"),
          prefix("2001:db8:a:200::/64")
        ])[{nil, :ipv6}]

      map = PrefixTree.space_map(node)

      assert map.level == 56
      assert {map.allocated, map.total} == {4, 256}
      assert length(map.cells) == 256

      assert Enum.map(Enum.take(map.cells, 6), & &1.state) ==
               [:allocated, :allocated, :partial, :free, :free, :allocated]

      assert Enum.at(map.cells, 1).child.prefix.id == "2001:db8:a:100::/56"
    end

    test "coarsens the map when the planning level has too many cells" do
      [node] =
        PrefixTree.build([prefix("2001:db8::/32"), prefix("2001:db8:1::/48")])[{nil, :ipv6}]

      map = PrefixTree.space_map(node)

      assert {map.level, map.cell_length, length(map.cells)} == {48, 40, 256}
      assert {map.allocated, map.total} == {1, 65_536}
      assert hd(map.cells).state == :partial
    end

    test "counts huge allocations without enumerating planning blocks or counting overlaps twice" do
      [node] =
        PrefixTree.build([
          prefix("2001:db8::/32"),
          prefix("2001:db8::/33"),
          prefix("2001:db8:8000::/64")
        ])[{nil, :ipv6}]

      map = PrefixTree.space_map(node)
      assert {map.allocated, map.total, length(map.cells)} == {2_147_483_649, 4_294_967_296, 256}

      [node] =
        PrefixTree.build([
          prefix("2001:db8::/48"),
          prefix("2001:db8:0:1::/80"),
          prefix("2001:db8:0:1:1::/80"),
          prefix("2001:db8:0:2::/64"),
          prefix("2001:db8:0:3::/64"),
          prefix("2001:db8:0:4::/64")
        ])[{nil, :ipv6}]

      assert PrefixTree.space_map(node).allocated == 4
    end

    test "maps every address of a small IPv4 leaf" do
      [node] = PrefixTree.build([prefix("192.0.2.0/29")])[{nil, :ipv4}]
      map = PrefixTree.address_map(node, [address("192.0.2.1"), address("192.0.2.5")])

      assert Enum.map(map.cells, & &1.state) ==
               [:network, :used, :free, :free, :free, :used, :free, :broadcast]

      assert {map.used, map.usable, map.percent} == {2, 6, 33}

      [point] = PrefixTree.build([prefix("192.0.2.8/31")])[{nil, :ipv4}]
      assert PrefixTree.address_map(point, []).usable == 2
    end
  end

  describe "AddressAssignment" do
    test "reads the method from collector metadata, most explicit first" do
      assert AddressAssignment.method(address("2001:db8::10", %{"assignment" => "DHCPv6"})) ==
               :dhcp

      assert AddressAssignment.method(address("2001:db8::a1b2", %{"temporary" => true})) ==
               :slaac

      assert AddressAssignment.method(address("2001:db8::1", %{"protocol" => "kernel_ra"})) ==
               :slaac

      assert AddressAssignment.method(address("10.0.0.5", %{"dynamic" => false})) == :static
      assert AddressAssignment.method(address("2001:db8::21b:21ff:fe3c:4d5e")) == :slaac
      assert AddressAssignment.method(address("2001:db8::99")) == :unknown

      assert AddressAssignment.temporary?(address("2001:db8::a1b2", %{"temporary" => true}))
      refute AddressAssignment.temporary?(address("2001:db8::99"))
      assert AddressAssignment.label(:dhcp, :ipv6) == "DHCPv6"
      assert AddressAssignment.label(:dhcp, :ipv4) == "DHCP"
    end
  end
end
