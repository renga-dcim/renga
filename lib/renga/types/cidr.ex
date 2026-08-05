defmodule Renga.Types.Cidr do
  @moduledoc """
  Ecto type for PostgreSQL `cidr` network prefixes.

  Parsing is shared with `Renga.Types.Inet`, then this type rejects host bits so
  invalid networks become changeset errors instead of PostgreSQL exceptions.
  """

  use Ecto.Type

  import Bitwise

  alias Renga.Types.Inet

  def type, do: :cidr

  def cast(value) do
    with {:ok, inet} <- Inet.cast(value) do
      validate_network(inet)
    end
  end

  def dump(%Postgrex.INET{} = inet), do: validate_network(inet)
  def dump(_value), do: :error

  def load(%Postgrex.INET{} = inet), do: validate_network(inet)
  def load(_value), do: :error

  defp validate_network(%Postgrex.INET{address: address, netmask: netmask} = inet)
       when tuple_size(address) == 4 do
    validate_network(inet, address, netmask || 32, 8, 32)
  end

  defp validate_network(%Postgrex.INET{address: address, netmask: netmask} = inet)
       when tuple_size(address) == 8 do
    validate_network(inet, address, netmask || 128, 16, 128)
  end

  defp validate_network(_inet), do: :error

  defp validate_network(inet, address, netmask, segment_bits, total_bits) do
    value =
      address
      |> Tuple.to_list()
      |> Enum.reduce(0, fn segment, value -> (value <<< segment_bits) + segment end)

    host_bits = total_bits - netmask
    network = (value >>> host_bits) <<< host_bits

    if value == network do
      {:ok, %{inet | netmask: netmask}}
    else
      :error
    end
  end
end
