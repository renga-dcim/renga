defmodule Renga.IPAM.AddressAssignment do
  @moduledoc """
  How an observed address was assigned, and whether it is a temporary
  privacy address (RFD 8, "Prefixes": IPv6 presentation).

  Collectors report addresses with free-form metadata, so the method is
  read from the keys collectors commonly send, most explicit first:

    * `"assignment"` - `static`, `slaac`, `dhcpv6`, or `dhcp`;
    * `"temporary"` - `true` for RFC 8981 privacy addresses, which are SLAAC;
    * `"protocol"` or `"proto"` - iproute2's origin: `kernel_ra` or `ra` is
      SLAAC, `dhcp` is DHCP, `static` or `boot` is static;
    * `"dynamic"` - iproute2's flag; `false` means static;
    * an EUI-64 interface identifier (`ff:fe` in its middle) is SLAAC.

  Anything else is `:unknown` rather than a guess.
  """

  import Bitwise

  alias Renga.IPAM.Cidr

  @doc "`:static`, `:slaac`, `:dhcp`, or `:unknown`."
  def method(%{metadata: metadata} = address) do
    metadata = metadata || %{}

    [
      fn -> explicit(metadata["assignment"]) end,
      fn -> if metadata["temporary"] == true, do: :slaac end,
      fn -> protocol(metadata["protocol"] || metadata["proto"]) end,
      fn -> if metadata["dynamic"] == false, do: :static end,
      fn -> if eui64?(address.address), do: :slaac end
    ]
    |> Enum.find_value(:unknown, & &1.())
  end

  @doc "Whether the address is a temporary privacy address."
  def temporary?(%{metadata: metadata}), do: (metadata || %{})["temporary"] == true

  @doc "A label for a method, naming DHCPv6 for IPv6 addresses."
  def label(:static, _family), do: "Static"
  def label(:slaac, _family), do: "SLAAC"
  def label(:dhcp, :ipv6), do: "DHCPv6"
  def label(:dhcp, :ipv4), do: "DHCP"
  def label(:unknown, _family), do: "Unknown"

  defp explicit(value) when is_binary(value) do
    case String.downcase(value) do
      "static" -> :static
      "slaac" -> :slaac
      dhcp when dhcp in ~w(dhcp dhcpv4 dhcpv6) -> :dhcp
      _other -> nil
    end
  end

  defp explicit(_value), do: nil

  defp protocol(value) when value in ~w(kernel_ra ra), do: :slaac
  defp protocol("dhcp"), do: :dhcp
  defp protocol(value) when value in ~w(static boot), do: :static
  defp protocol(_value), do: nil

  # Modified EUI-64 places ff:fe between the two halves of the MAC address.
  defp eui64?(%Postgrex.INET{address: address} = inet) when tuple_size(address) == 8 do
    (Cidr.to_integer(inet) >>> 24 &&& 0xFFFF) == 0xFFFE
  end

  defp eui64?(_address), do: false
end
