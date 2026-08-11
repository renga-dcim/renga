# credo:disable-for-this-file Credo.Check.Refactor.CyclomaticComplexity
defmodule Renga.Enrollment.SafeURL do
  @moduledoc "Validates and pins outbound enrollment URLs to public IP addresses."

  import Bitwise

  def validate(value, allow_http \\ false)

  def validate(value, allow_http) when is_binary(value) do
    uri = URI.parse(value)
    test_http = allow_http and Code.ensure_loaded?(Mix) and Mix.env() == :test
    schemes = if test_http, do: ["https", "http"], else: ["https"]
    default_port = if uri.scheme == "http", do: 80, else: 443

    with true <- uri.scheme in schemes,
         true <- is_binary(uri.host) and uri.host != "",
         true <- is_nil(uri.userinfo) and is_nil(uri.query) and is_nil(uri.fragment),
         true <- is_nil(uri.port) or uri.port == default_port,
         {:error, _} <- parse_address(uri.host) do
      :ok
    else
      {:ok, address} -> if public?(address), do: :ok, else: {:error, :invalid_configuration}
      _ -> {:error, :invalid_configuration}
    end
  end

  def validate(_, _), do: {:error, :invalid_configuration}

  def pin(url) do
    uri = URI.parse(url)
    resolver = Application.get_env(:renga, :oidc_resolver, &default_resolver/1)

    with {:ok, addresses} when is_list(addresses) and addresses != [] <- resolver.(uri.host),
         true <- Enum.all?(addresses, &public?/1),
         address <- hd(addresses) do
      host = address |> :inet.ntoa() |> to_string()
      pinned = %{uri | host: host} |> URI.to_string()
      {:ok, pinned, uri.host, address}
    else
      _ -> {:error, :forbidden_address}
    end
  rescue
    _ -> {:error, :forbidden_address}
  end

  def public?({a, b, c, d} = address)
      when a in 0..255 and b in 0..255 and c in 0..255 and d in 0..255 do
    value = ipv4_value(address)

    not Enum.any?(
      [
        {"0.0.0.0", 8},
        {"10.0.0.0", 8},
        {"100.64.0.0", 10},
        {"127.0.0.0", 8},
        {"169.254.0.0", 16},
        {"172.16.0.0", 12},
        {"192.0.0.0", 24},
        {"192.0.2.0", 24},
        {"192.88.99.0", 24},
        {"192.168.0.0", 16},
        {"198.18.0.0", 15},
        {"198.51.100.0", 24},
        {"203.0.113.0", 24},
        {"224.0.0.0", 4},
        {"240.0.0.0", 4}
      ],
      fn {network, bits} -> in_prefix?(value, ipv4_value(network), bits, 32) end
    )
  end

  def public?({a, b, c, d, e, f, g, h} = address) do
    value = ipv6_value(address)
    mapped? = a == 0 and b == 0 and c == 0 and d == 0 and e == 0 and f == 0xFFFF

    if mapped? do
      public?({g >>> 8, g &&& 255, h >>> 8, h &&& 255})
    else
      # Default-deny everything outside global unicast, then subtract IANA
      # special-purpose space that must never become an SSRF route.
      in_prefix?(value, ipv6_value("2000::"), 3, 128) and
        not Enum.any?(
          [
            {"64:ff9b::", 96},
            {"64:ff9b:1::", 48},
            {"100::", 64},
            {"2001::", 23},
            {"2001:db8::", 32},
            {"2002::", 16},
            {"3fff::", 20},
            {"fc00::", 7},
            {"fec0::", 10},
            {"fe80::", 10},
            {"ff00::", 8}
          ],
          fn {network, bits} -> in_prefix?(value, ipv6_value(network), bits, 128) end
        )
    end
  end

  def public?(_), do: false

  defp default_resolver(host) do
    hostname = String.to_charlist(host)

    addresses =
      [:inet, :inet6]
      |> Enum.flat_map(fn family ->
        case :inet.getaddrs(hostname, family) do
          {:ok, found} -> found
          {:error, _} -> []
        end
      end)
      |> Enum.uniq()

    case addresses do
      [] -> {:error, :nxdomain}
      found -> {:ok, found}
    end
  end

  defp parse_address(host), do: :inet.parse_address(String.to_charlist(host))

  defp ipv4_value(value) when is_binary(value),
    do: value |> parse_address() |> elem(1) |> ipv4_value()

  defp ipv4_value({a, b, c, d}), do: (a <<< 24) + (b <<< 16) + (c <<< 8) + d

  defp ipv6_value(value) when is_binary(value),
    do: value |> parse_address() |> elem(1) |> ipv6_value()

  defp ipv6_value(tuple), do: tuple |> Tuple.to_list() |> Enum.reduce(0, &(&2 <<< 16 ||| &1))

  defp in_prefix?(value, network, bits, width),
    do: value >>> (width - bits) == network >>> (width - bits)
end
