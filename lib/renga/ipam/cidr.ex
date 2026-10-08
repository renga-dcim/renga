defmodule Renga.IPAM.Cidr do
  @moduledoc """
  Integer arithmetic over `Postgrex.INET` prefixes and addresses.

  The database answers containment for stored rows; the prefix views also
  need to reason about space nobody stored, such as the free /56s of a /48,
  so this module treats a prefix as an integer network and a length.
  """

  import Bitwise

  @doc "`:ipv4` or `:ipv6`."
  def family(%Postgrex.INET{address: address}) when tuple_size(address) == 4, do: :ipv4
  def family(%Postgrex.INET{address: address}) when tuple_size(address) == 8, do: :ipv6

  @doc "Address width in bits for a family."
  def bits(:ipv4), do: 32
  def bits(:ipv6), do: 128

  @doc "The prefix length, treating a bare address as a host prefix."
  def length(%Postgrex.INET{netmask: nil} = inet), do: inet |> family() |> bits()
  def length(%Postgrex.INET{netmask: netmask}), do: netmask

  @doc "How many addresses a prefix holds."
  def size(inet), do: 1 <<< (bits(family(inet)) - __MODULE__.length(inet))

  @doc "The address as an integer."
  def to_integer(%Postgrex.INET{address: address} = inet) do
    segment_bits = if family(inet) == :ipv4, do: 8, else: 16

    address
    |> Tuple.to_list()
    |> Enum.reduce(0, fn segment, value -> (value <<< segment_bits) + segment end)
  end

  @doc "Builds a prefix from an integer network, family, and length."
  def from_integer(value, family, length) do
    {segment_bits, count} = if family == :ipv4, do: {8, 4}, else: {16, 8}
    mask = (1 <<< segment_bits) - 1

    address =
      (count - 1)..0//-1
      |> Enum.map(&(value >>> (&1 * segment_bits) &&& mask))
      |> List.to_tuple()

    %Postgrex.INET{address: address, netmask: length}
  end

  @doc "Whether `outer` contains `inner` (a prefix contains itself)."
  def contains?(outer, inner) do
    family(outer) == family(inner) and __MODULE__.length(outer) <= __MODULE__.length(inner) and
      network_at(inner, __MODULE__.length(outer)) == network_at(outer, __MODULE__.length(outer))
  end

  @doc "The network of `inet` truncated to `length` bits, as an integer."
  def network_at(inet, length) do
    host_bits = bits(family(inet)) - length
    (to_integer(inet) >>> host_bits) <<< host_bits
  end

  @doc """
  Formats a prefix (`10.0.0.0/24`) or, for a host prefix or bare address,
  just the address. IPv6 is compressed as RFC 5952 recommends.
  """
  def format(%Postgrex.INET{address: address} = inet) do
    text = address |> :inet.ntoa() |> List.to_string()
    length = __MODULE__.length(inet)

    if inet.netmask && length < bits(family(inet)), do: "#{text}/#{length}", else: text
  end

  @doc """
  Splits an IPv6 address into the part shared with `prefix` and the rest,
  for dimming the shared prefix so interface identifiers stand out. Splits
  fall on the colon groups the prefix fully covers.
  """
  def split_ipv6(%Postgrex.INET{} = address, prefix_length) do
    groups =
      address.address
      |> Tuple.to_list()
      |> Enum.map(&Integer.to_string(&1, 16))
      |> Enum.map(&String.downcase/1)

    shared = div(prefix_length, 16)
    {head, tail} = Enum.split(groups, shared)
    tail = compress(tail)

    # A compressed identifier brings its own "::", so the shared part only
    # keeps its trailing colon when the identifier starts with a group.
    separator = if head != [] and not String.starts_with?(tail, "::"), do: ":", else: ""
    {Enum.join(head, ":") <> separator, tail}
  end

  # Compresses the longest run of zero groups in the interface part.
  defp compress(groups) do
    runs =
      groups
      |> Enum.with_index()
      |> Enum.chunk_by(fn {group, _index} -> group == "0" end)
      |> Enum.filter(fn [{group, _index} | _rest] -> group == "0" end)

    case Enum.max_by(runs, &Kernel.length/1, fn -> [] end) do
      run when Kernel.length(run) >= 2 ->
        {_group, first} = hd(run)
        {before, rest} = Enum.split(groups, first)
        after_run = Enum.drop(rest, Kernel.length(run))
        Enum.join(before, ":") <> "::" <> Enum.join(after_run, ":")

      _short ->
        Enum.join(groups, ":")
    end
  end
end
