defmodule Renga.Topology.NeighborIdentifier do
  @moduledoc "Subtype-aware validation and comparison for LLDP/CDP endpoint identifiers."

  alias Renga.Inventory.ResourceIdentifier
  alias Renga.Types.Inet

  @mac_address ~r/\A(?:[0-9a-fA-F]{12}|(?:[0-9a-fA-F]{2}:){5}[0-9a-fA-F]{2}|(?:[0-9a-fA-F]{2}-){5}[0-9a-fA-F]{2}|(?:[0-9a-fA-F]{4}\.){2}[0-9a-fA-F]{4})\z/

  def mac_address?(value) when is_binary(value),
    do: Regex.match?(@mac_address, String.trim(value))

  def mac_address?(_value), do: false

  def normalize_chassis("network_address", value) when is_binary(value) do
    case Inet.cast(value) do
      {:ok, %Postgrex.INET{address: address, netmask: netmask}} ->
        host_mask = if tuple_size(address) == 4, do: 32, else: 128
        address = address |> :inet.ntoa() |> to_string()
        if netmask in [nil, host_mask], do: address, else: "#{address}/#{netmask}"

      :error ->
        value |> String.trim() |> String.downcase()
    end
  end

  def normalize_chassis(kind, value) when is_binary(value) do
    trimmed = String.trim(value)

    cond do
      kind == "mac_address" ->
        ResourceIdentifier.normalize_value("mac_address", trimmed)

      is_nil(kind) and mac_address?(trimmed) ->
        ResourceIdentifier.normalize_value("mac_address", trimmed)

      kind == "name" ->
        String.downcase(trimmed)

      true ->
        trimmed
    end
  end

  def normalize_port("name", value) when is_binary(value), do: String.trim(value)
  def normalize_port(kind, value), do: normalize_chassis(kind, value)
end
