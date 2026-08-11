defmodule RengaWeb.TrustedProxySourceTest do
  use ExUnit.Case, async: true

  alias RengaWeb.TrustedProxySource

  test "uses the direct source when no proxies are trusted" do
    conn = conn({203, 0, 113, 7}, "198.51.100.9")
    assert TrustedProxySource.resolve(conn, []) == {203, 0, 113, 7}
  end

  test "ignores spoofed forwarding from an untrusted peer" do
    conn = conn({203, 0, 113, 7}, "198.51.100.9")
    assert TrustedProxySource.resolve(conn, ["10.0.0.0/8"]) == {203, 0, 113, 7}
  end

  test "walks a trusted IPv4 proxy chain from right to left" do
    conn = conn({10, 0, 0, 4}, "198.51.100.9, 10.1.2.3")

    assert TrustedProxySource.resolve(conn, ["10.0.0.0/8"]) == {198, 51, 100, 9}
  end

  test "supports IPv6 proxy CIDRs" do
    conn = conn({0x2001, 0xDB8, 1, 0, 0, 0, 0, 4}, "2001:db9::8, 2001:db8:2::3")

    assert TrustedProxySource.resolve(conn, ["2001:db8::/32"]) ==
             {0x2001, 0xDB9, 0, 0, 0, 0, 0, 8}
  end

  test "falls back for malformed, non-bare, or ambiguous headers" do
    peer = {10, 0, 0, 4}

    for value <- ["unknown", "198.51.100.9:1234", "198.51.100.9,,10.0.0.3"] do
      assert TrustedProxySource.resolve(conn(peer, value), ["10.0.0.0/8"]) == peer
    end

    ambiguous =
      peer
      |> conn("198.51.100.9")
      |> Map.update!(:req_headers, &[{"x-forwarded-for", "198.51.100.10"} | &1])

    assert TrustedProxySource.resolve(ambiguous, ["10.0.0.0/8"]) == peer
  end

  test "invalid CIDR configuration trusts no peer" do
    conn = conn({10, 0, 0, 4}, "198.51.100.9")
    assert TrustedProxySource.resolve(conn, ["10.0.0.0/99"]) == {10, 0, 0, 4}
  end

  defp conn(remote_ip, forwarded) do
    Plug.Test.conn(:get, "/")
    |> Map.put(:remote_ip, remote_ip)
    |> Plug.Conn.put_req_header("x-forwarded-for", forwarded)
  end
end
