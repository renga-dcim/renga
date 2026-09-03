defmodule Renga.Catalog.JSONB do
  @moduledoc """
  Validates catalog metadata against PostgreSQL JSONB's representable value domain.
  """

  @max_integer_digits 131_072
  @max_fractional_digits 16_383

  def validate(%Decimal{} = value) do
    value = Decimal.normalize(value)

    case value do
      %Decimal{coef: coefficient, exp: exponent} when is_integer(coefficient) ->
        coefficient_digits = digit_count(coefficient)
        integer_digits = max(coefficient_digits + exponent, 0)
        fractional_digits = max(-exponent, 0)

        if integer_digits <= @max_integer_digits and
             fractional_digits <= @max_fractional_digits do
          :ok
        else
          {:error, "contains a number PostgreSQL JSONB cannot represent"}
        end

      _special_decimal ->
        {:error, "contains a number PostgreSQL JSONB cannot represent"}
    end
  end

  def validate(value) when is_map(value) do
    Enum.reduce_while(value, :ok, fn {key, nested}, :ok ->
      if valid_string?(key) do
        continue(validate(nested))
      else
        {:halt, {:error, "must contain valid JSON object keys"}}
      end
    end)
  end

  def validate(value) when is_list(value) do
    Enum.reduce_while(value, :ok, fn nested, :ok -> continue(validate(nested)) end)
  end

  def validate(value) when is_binary(value) do
    if valid_string?(value),
      do: :ok,
      else: {:error, "contains a string PostgreSQL JSONB cannot represent"}
  end

  def validate(value) when is_integer(value) do
    if digit_count(value) <= @max_integer_digits,
      do: :ok,
      else: {:error, "contains a number PostgreSQL JSONB cannot represent"}
  end

  def validate(value) when is_float(value), do: :ok

  def validate(value) when is_boolean(value) or is_nil(value), do: :ok
  def validate(_value), do: {:error, "contains a value PostgreSQL JSONB cannot represent"}

  defp continue(:ok), do: {:cont, :ok}
  defp continue({:error, _message} = error), do: {:halt, error}

  defp valid_string?(value) when is_binary(value) do
    String.valid?(value) and not String.contains?(value, <<0>>)
  end

  defp valid_string?(_value), do: false

  defp digit_count(0), do: 1

  defp digit_count(value) do
    value
    |> abs()
    |> Integer.digits()
    |> length()
  end
end
