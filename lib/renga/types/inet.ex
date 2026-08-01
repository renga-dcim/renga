defmodule Renga.Types.Inet do
  @moduledoc """
  Ecto type for PostgreSQL `inet` values.

  Postgrex exposes native network values as `Postgrex.INET`, but it does not
  cast user/API strings itself. This type keeps interface addresses stored as
  real Postgres network values while letting callers submit ordinary strings
  such as "192.0.2.10/24" or "2001:db8::10/64".
  """

  use Ecto.Type

  def type, do: :inet

  def cast(%Postgrex.INET{} = inet), do: validate_inet(inet)

  def cast(value) when is_binary(value) do
    value
    |> String.trim()
    |> parse_inet()
  end

  def cast(_value), do: :error

  def dump(%Postgrex.INET{} = inet), do: validate_inet(inet)
  def dump(_value), do: :error

  def load(%Postgrex.INET{} = inet), do: validate_inet(inet)
  def load(_value), do: :error

  defp parse_inet(""), do: :error

  defp parse_inet(value) do
    case String.split(value, "/", parts: 2) do
      [address] ->
        parse_address(address, nil)

      [address, netmask] ->
        case Integer.parse(netmask) do
          {netmask, ""} -> parse_address(address, netmask)
          _invalid -> :error
        end
    end
  end

  defp parse_address(address, netmask) do
    address
    |> String.to_charlist()
    |> :inet.parse_strict_address()
    |> case do
      {:ok, parsed_address} ->
        validate_inet(%Postgrex.INET{address: parsed_address, netmask: netmask})

      {:error, _reason} ->
        :error
    end
  end

  defp validate_inet(%Postgrex.INET{address: {_, _, _, _}, netmask: netmask} = inet)
       when is_nil(netmask) or netmask in 0..32 do
    {:ok, inet}
  end

  defp validate_inet(%Postgrex.INET{address: {_, _, _, _, _, _, _, _}, netmask: netmask} = inet)
       when is_nil(netmask) or netmask in 0..128 do
    {:ok, inet}
  end

  defp validate_inet(_inet), do: :error
end
