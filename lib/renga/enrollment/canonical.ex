defmodule Renga.Enrollment.Canonical do
  @moduledoc "Deterministic, typed serialization for enrollment transcript values."

  def encode(value), do: IO.iodata_to_binary(render(value))
  def digest(value), do: :crypto.hash(:sha256, encode(value))

  defp render(nil), do: "n"
  defp render(true), do: "t"
  defp render(false), do: "f"

  defp render(value) when is_binary(value),
    do: ["s", Integer.to_string(byte_size(value)), ":", value]

  defp render(value) when is_integer(value), do: ["i", Integer.to_string(value), ";"]

  defp render(value) when is_float(value) do
    if finite?(value),
      do: ["d", :erlang.float_to_binary(value, [:short]), ";"],
      else: raise(ArgumentError, "non-finite number")
  end

  defp render(value) when is_list(value),
    do: ["l", Integer.to_string(length(value)), ":", Enum.map(value, &render/1)]

  defp render(value) when is_map(value) do
    pairs = Enum.map(value, fn {key, item} when is_binary(key) -> {key, item} end) |> Enum.sort()

    [
      "m",
      Integer.to_string(length(pairs)),
      ":",
      Enum.map(pairs, fn {key, item} -> [render(key), render(item)] end)
    ]
  end

  defp finite?(number), do: number < 1.0e308 and number > -1.0e308
end
