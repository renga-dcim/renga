defmodule Renga.Accounts.OIDC.Destinations do
  @moduledoc """
  Where Renga may send requests for an organization's identity provider
  (RFD 15, "Organization providers").

  An organization owner chooses that provider's issuer, but does not control
  the deployment's network, so every server-side request made for it
  (discovery, signing keys, the token exchange) goes only to public
  addresses. Renga resolves the host for each request, refuses it when any
  address it resolves to is loopback, link-local, private, or otherwise not
  public, and connects to the address it checked, so a DNS change between
  the check and the connection cannot reach somewhere else. Redirects are
  never followed (`Renga.Accounts.OIDC.HTTP`).

  An operator may allow the destinations of an internal identity provider
  with `ORGANIZATION_PROVIDER_ALLOW`, a comma-separated list of exact host
  names and address ranges (`idp.corp.internal,10.20.0.0/16`). Organization
  owners cannot add exceptions. Deployment providers are configured by the
  operator and are not subject to this policy.
  """

  import Bitwise

  @doc """
  Checks `url` for an organization provider request. Returns
  `{:ok, address}`, the address to connect to, or
  `{:error, :destination_not_allowed}`.
  """
  def check(url) when is_binary(url) do
    with %URI{scheme: "https", host: host} when is_binary(host) and host != "" <- URI.parse(url),
         host = String.downcase(host),
         {:ok, addresses} <- resolve(host),
         true <- Enum.all?(addresses, &allowed?(host, &1)) do
      {:ok, hd(addresses)}
    else
      _refused -> {:error, :destination_not_allowed}
    end
  end

  # Every address the name resolves to, in both families. An address
  # literal is its own answer.
  defp resolve(host) do
    case :inet.parse_strict_address(String.to_charlist(host)) do
      {:ok, address} ->
        {:ok, [address]}

      {:error, _not_literal} ->
        resolver = Application.get_env(:renga, :oidc_resolver, &resolve_name/1)

        case resolver.(host) do
          {:ok, [_ | _] = addresses} -> {:ok, addresses}
          _none -> {:error, :nxdomain}
        end
    end
  end

  defp resolve_name(host) do
    name = String.to_charlist(host)

    addresses =
      for family <- [:inet, :inet6],
          {:ok, found} <- [:inet.getaddrs(name, family)],
          address <- found,
          do: address

    {:ok, Enum.uniq(addresses)}
  end

  defp allowed?(host, address) do
    public?(address) or operator_allowed?(host, address)
  end

  defp operator_allowed?(host, address) do
    Enum.any?(allowlist(), fn
      {:host, allowed} -> host == allowed
      {:range, network, bits} -> in_range?(address, network, bits)
    end)
  end

  @doc """
  Parses the operator's allowlist, as `config/runtime.exs` reads it from
  `ORGANIZATION_PROVIDER_ALLOW`. Raises on an entry it cannot read, so a
  typo stops the boot instead of silently allowing nothing.
  """
  def parse_allowlist(value) when is_binary(value) do
    value
    |> String.split(",", trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.map(&parse_entry/1)
  end

  defp parse_entry(entry) do
    case String.split(entry, "/") do
      [address, bits] -> parse_range(entry, address, bits)
      [host] -> parse_host(entry, host)
    end
  end

  defp parse_range(entry, address, bits) do
    with {:ok, network} <- :inet.parse_strict_address(String.to_charlist(address)),
         {bits, ""} <- Integer.parse(bits),
         true <- bits >= 0 and bits <= tuple_size(network) * width(network) do
      {:range, network, bits}
    else
      _invalid -> raise ArgumentError, "invalid ORGANIZATION_PROVIDER_ALLOW range: #{entry}"
    end
  end

  defp parse_host(entry, host) do
    case :inet.parse_strict_address(String.to_charlist(host)) do
      {:ok, address} ->
        {:range, address, tuple_size(address) * width(address)}

      {:error, _not_literal} ->
        if Regex.match?(~r/^[a-z0-9]([a-z0-9.-]*[a-z0-9])?$/i, host),
          do: {:host, String.downcase(host)},
          else: raise(ArgumentError, "invalid ORGANIZATION_PROVIDER_ALLOW host: #{entry}")
    end
  end

  defp allowlist, do: Application.get_env(:renga, :organization_provider_allow, [])

  @doc """
  Whether `address` is a public unicast address: not loopback, link-local
  (which includes cloud metadata services), private, shared, multicast,
  reserved, or documentation space.
  """
  def public?({_, _, _, _} = address) do
    not Enum.any?(
      [
        {{0, 0, 0, 0}, 8},
        {{10, 0, 0, 0}, 8},
        {{100, 64, 0, 0}, 10},
        {{127, 0, 0, 0}, 8},
        {{169, 254, 0, 0}, 16},
        {{172, 16, 0, 0}, 12},
        {{192, 0, 0, 0}, 24},
        {{192, 0, 2, 0}, 24},
        {{192, 88, 99, 0}, 24},
        {{192, 168, 0, 0}, 16},
        {{198, 18, 0, 0}, 15},
        {{198, 51, 100, 0}, 24},
        {{203, 0, 113, 0}, 24},
        {{224, 0, 0, 0}, 4},
        {{240, 0, 0, 0}, 4}
      ],
      fn {network, bits} -> in_range?(address, network, bits) end
    )
  end

  # Only global unicast (2000::/3) is public, less the ranges inside it that
  # tunnel or translate to IPv4 or are reserved. An IPv4-mapped address is
  # judged as the IPv4 address it carries.
  def public?({0, 0, 0, 0, 0, 0xFFFF, high, low}),
    do: public?({high >>> 8, high &&& 0xFF, low >>> 8, low &&& 0xFF})

  def public?({_, _, _, _, _, _, _, _} = address) do
    in_range?(address, {0x2000, 0, 0, 0, 0, 0, 0, 0}, 3) and
      not Enum.any?(
        [
          {{0x2001, 0, 0, 0, 0, 0, 0, 0}, 23},
          {{0x2001, 0x0DB8, 0, 0, 0, 0, 0, 0}, 32},
          {{0x2002, 0, 0, 0, 0, 0, 0, 0}, 16},
          {{0x3FFF, 0, 0, 0, 0, 0, 0, 0}, 20}
        ],
        fn {network, bits} -> in_range?(address, network, bits) end
      )
  end

  defp in_range?(address, network, bits)
       when tuple_size(address) == tuple_size(network) do
    total = tuple_size(address) * width(address)
    shift = total - bits
    to_integer(address) >>> shift == to_integer(network) >>> shift
  end

  defp in_range?(_address, _network, _bits), do: false

  defp width(address) when tuple_size(address) == 4, do: 8
  defp width(_address), do: 16

  defp to_integer(address) do
    size = width(address)

    address
    |> Tuple.to_list()
    |> Enum.reduce(0, fn part, acc -> (acc <<< size) + part end)
  end
end
