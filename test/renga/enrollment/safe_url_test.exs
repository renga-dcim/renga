defmodule Renga.Enrollment.SafeURLTest do
  use ExUnit.Case, async: true

  alias Renga.Enrollment.SafeURL

  test "allows ordinary global-unicast IPv6" do
    assert public?("2606:4700:4700::1111")
  end

  test "rejects non-global and IANA special-purpose IPv6 ranges" do
    for address <- [
          "::1",
          "1000::1",
          "4000::1",
          "64:ff9b::c0a8:101",
          "64:ff9b:1::a00:1",
          "100::1",
          "2001::1",
          "2001:20::1",
          "2001:db8::1",
          "2002:c0a8:101::1",
          "3fff::1",
          "fc00::1",
          "fec0::1",
          "fe80::1",
          "ff00::1"
        ] do
      refute public?(address), "expected #{address} to be rejected"
    end
  end

  test "IPv4-mapped IPv6 inherits private-address rejection" do
    refute public?("::ffff:192.168.1.1")
    assert public?("::ffff:8.8.8.8")
  end

  defp public?(address) do
    {:ok, parsed} = :inet.parse_address(String.to_charlist(address))
    SafeURL.public?(parsed)
  end
end
