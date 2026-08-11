defmodule RengaWeb.TrustedProxySource do
  @moduledoc """
  Resolves a request source through an explicitly trusted proxy boundary.

  Forwarded data is considered only when the TCP peer is in a configured
  CIDR. Any ambiguous or malformed forwarding data fails closed to the peer.
  """

  import Bitwise

  @type cidr :: String.t()

  @spec resolve(Plug.Conn.t(), [cidr()]) :: :inet.ip_address()
  def resolve(conn, trusted_cidrs) do
    with {:ok, networks} <- parse_networks(trusted_cidrs),
         true <- trusted?(conn.remote_ip, networks),
         [header] <- Plug.Conn.get_req_header(conn, "x-forwarded-for"),
         {:ok, forwarded} <- parse_forwarded(header) do
      select_source(conn.remote_ip, forwarded, networks)
    else
      _ -> conn.remote_ip
    end
  end

  defp parse_networks(cidrs) when is_list(cidrs) do
    Enum.reduce_while(cidrs, {:ok, []}, fn cidr, {:ok, networks} ->
      case parse_network(cidr) do
        {:ok, network} -> {:cont, {:ok, [network | networks]}}
        :error -> {:halt, :error}
      end
    end)
  end

  defp parse_networks(_cidrs), do: :error

  defp parse_network(cidr) when is_binary(cidr) do
    with [address, prefix] <- String.split(cidr, "/"),
         {:ok, ip} <- parse_ip(address),
         {prefix, ""} <- Integer.parse(prefix),
         bits <- address_bits(ip),
         true <- prefix >= 0 and prefix <= bits do
      {:ok, {ip_integer(ip) >>> (bits - prefix), prefix, tuple_size(ip)}}
    else
      _ -> :error
    end
  end

  defp parse_network(_cidr), do: :error

  defp parse_forwarded(header) do
    items = String.split(header, ",", trim: false)

    Enum.reduce_while(items, {:ok, []}, fn item, {:ok, addresses} ->
      case item |> String.trim() |> parse_ip() do
        {:ok, ip} -> {:cont, {:ok, [ip | addresses]}}
        :error -> {:halt, :error}
      end
    end)
    |> case do
      {:ok, []} -> :error
      {:ok, reversed} -> {:ok, Enum.reverse(reversed)}
      :error -> :error
    end
  end

  defp parse_ip(value) when is_binary(value) and value != "" do
    case :inet.parse_strict_address(String.to_charlist(value)) do
      {:ok, ip} -> {:ok, ip}
      {:error, _reason} -> :error
    end
  end

  defp parse_ip(_value), do: :error

  defp select_source(peer, forwarded, networks) do
    Enum.reduce_while(Enum.reverse(forwarded), peer, fn address, _current ->
      if trusted?(address, networks), do: {:cont, address}, else: {:halt, address}
    end)
  end

  defp trusted?(ip, networks) do
    size = tuple_size(ip)
    bits = address_bits(ip)

    Enum.any?(networks, fn
      {network, prefix, ^size} -> ip_integer(ip) >>> (bits - prefix) == network
      _other_family -> false
    end)
  end

  defp address_bits(ip) when tuple_size(ip) == 4, do: 32
  defp address_bits(ip) when tuple_size(ip) == 8, do: 128

  defp ip_integer(ip) do
    part_bits = div(address_bits(ip), tuple_size(ip))

    ip
    |> Tuple.to_list()
    |> Enum.reduce(0, fn part, integer -> (integer <<< part_bits) + part end)
  end
end
