defmodule Renga.JSON do
  @moduledoc """
  PostgreSQL JSON codec that preserves arbitrary-precision JSON numbers as decimals.
  """

  def decode(value), do: Jason.decode(value, floats: :decimals)
  def decode!(value), do: Jason.decode!(value, floats: :decimals)

  def encode(value), do: Jason.encode(decimal_fragments(value))
  def encode!(value), do: Jason.encode!(decimal_fragments(value))
  def encode_to_iodata!(value), do: Jason.encode_to_iodata!(decimal_fragments(value))

  defp decimal_fragments(%Decimal{coef: coefficient} = value) when is_integer(coefficient) do
    value
    |> Decimal.to_string(:normal)
    |> Jason.Fragment.new()
  end

  defp decimal_fragments(%Decimal{} = value) do
    raise Jason.EncodeError, message: "cannot encode Decimal #{inspect(value)} as JSON"
  end

  defp decimal_fragments(value) when is_map(value) and not is_struct(value) do
    Map.new(value, fn {key, nested} -> {key, decimal_fragments(nested)} end)
  end

  defp decimal_fragments(value) when is_list(value), do: Enum.map(value, &decimal_fragments/1)
  defp decimal_fragments(value), do: value
end
