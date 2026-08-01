defmodule Renga.Types.MacAddress do
  @moduledoc """
  Ecto type for PostgreSQL `macaddr` values.

  Postgrex stores native MAC addresses as `Postgrex.MACADDR`. This type lets
  callers submit common string forms while keeping interface MACs queryable as
  native Postgres network hardware addresses.
  """

  use Ecto.Type

  def type, do: :macaddr

  def cast(%Postgrex.MACADDR{} = mac_address), do: validate_mac_address(mac_address)

  def cast(value) when is_binary(value) do
    value
    |> String.trim()
    |> parse_mac_address()
  end

  def cast(_value), do: :error

  def dump(%Postgrex.MACADDR{} = mac_address), do: validate_mac_address(mac_address)
  def dump(_value), do: :error

  def load(%Postgrex.MACADDR{} = mac_address), do: validate_mac_address(mac_address)
  def load(_value), do: :error

  defp parse_mac_address(""), do: :error

  defp parse_mac_address(value) do
    value
    |> String.downcase()
    |> String.replace(~r/[^0-9a-f]/, "")
    |> parse_mac_bytes()
  end

  defp parse_mac_bytes(<<
         a::binary-size(2),
         b::binary-size(2),
         c::binary-size(2),
         d::binary-size(2),
         e::binary-size(2),
         f::binary-size(2)
       >>) do
    with {:ok, bytes} <- parse_hex_bytes([a, b, c, d, e, f]) do
      validate_mac_address(%Postgrex.MACADDR{address: List.to_tuple(bytes)})
    end
  end

  defp parse_mac_bytes(_value), do: :error

  defp parse_hex_bytes(parts) do
    Enum.reduce_while(parts, {:ok, []}, fn part, {:ok, bytes} ->
      case Integer.parse(part, 16) do
        {byte, ""} when byte in 0..255 -> {:cont, {:ok, [byte | bytes]}}
        _invalid -> {:halt, :error}
      end
    end)
    |> case do
      {:ok, bytes} -> {:ok, Enum.reverse(bytes)}
      :error -> :error
    end
  end

  defp validate_mac_address(%Postgrex.MACADDR{address: {a, b, c, d, e, f}} = mac_address)
       when a in 0..255 and b in 0..255 and c in 0..255 and d in 0..255 and e in 0..255 and
              f in 0..255 do
    {:ok, mac_address}
  end

  defp validate_mac_address(_mac_address), do: :error
end
