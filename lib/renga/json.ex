defmodule Renga.JSON do
  @moduledoc """
  PostgreSQL JSON codec that preserves arbitrary-precision JSON numbers as decimals.
  """

  @number ~r/^-?(?<integer>0|[1-9][0-9]*)(?:\.(?<fraction>[0-9]+))?(?:[eE](?<exponent>[+-]?[0-9]+))?$/
  @number_bytes ~c"0123456789.eE+-"

  def decode(value) do
    marker = "__renga_decimal_#{Base.encode16(:crypto.strong_rand_bytes(16))}__"

    value
    |> quote_fractional_numbers(marker)
    |> Jason.decode()
    |> case do
      {:ok, decoded} -> {:ok, restore_decimals(decoded, marker)}
      error -> error
    end
  end

  def decode!(value) do
    case decode(value) do
      {:ok, decoded} -> decoded
      {:error, error} -> raise error
    end
  end

  def encode(value), do: Jason.encode(decimal_fragments(value))
  def encode!(value), do: Jason.encode!(decimal_fragments(value))
  def encode_to_iodata!(value), do: Jason.encode_to_iodata!(decimal_fragments(value))

  defp decimal_fragments(%Decimal{coef: coefficient} = value) when is_integer(coefficient) do
    value
    |> decimal_lexeme()
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

  defp decimal_lexeme(%Decimal{sign: sign, coef: coefficient, exp: exponent}) do
    digits = Integer.to_string(coefficient)
    point = byte_size(digits) + exponent

    magnitude =
      cond do
        coefficient == 0 and exponent < 0 -> "0." <> String.duplicate("0", -exponent)
        coefficient == 0 -> "0"
        abs(exponent) > 1_000 -> digits <> "e" <> Integer.to_string(exponent)
        exponent >= 0 -> digits <> String.duplicate("0", exponent)
        point > 0 -> String.slice(digits, 0, point) <> "." <> String.slice(digits, point..-1//1)
        true -> "0." <> String.duplicate("0", -point) <> digits
      end

    if sign == -1, do: "-" <> magnitude, else: magnitude
  end

  defp quote_fractional_numbers(value, marker) do
    value
    |> scan_json(marker, false, false, [])
    |> IO.iodata_to_binary()
  end

  defp scan_json(<<>>, _marker, _in_string?, _escaped?, output),
    do: Enum.reverse(output)

  defp scan_json(<<byte, rest::binary>>, marker, true, escaped?, output) do
    cond do
      escaped? -> scan_json(rest, marker, true, false, [<<byte>> | output])
      byte == ?\\ -> scan_json(rest, marker, true, true, [<<byte>> | output])
      byte == ?" -> scan_json(rest, marker, false, false, [<<byte>> | output])
      true -> scan_json(rest, marker, true, false, [<<byte>> | output])
    end
  end

  defp scan_json(<<?", rest::binary>>, marker, false, false, output),
    do: scan_json(rest, marker, true, false, [<<?">> | output])

  defp scan_json(<<byte, _rest::binary>> = input, marker, false, false, output)
       when byte == ?- or byte in ?0..?9 do
    {candidate, rest} = take_number(input, [])

    encoded =
      if decimal_number?(candidate), do: [<<?">>, marker, candidate, <<?">>], else: candidate

    scan_json(rest, marker, false, false, [encoded | output])
  end

  defp scan_json(<<byte, rest::binary>>, marker, false, false, output),
    do: scan_json(rest, marker, false, false, [<<byte>> | output])

  defp take_number(<<byte, rest::binary>>, output) when byte in @number_bytes,
    do: take_number(rest, [<<byte>> | output])

  defp take_number(rest, output), do: {output |> Enum.reverse() |> IO.iodata_to_binary(), rest}

  defp decimal_number?(candidate) do
    Regex.match?(@number, candidate) and
      (String.contains?(candidate, ".") or String.contains?(candidate, ["e", "E"]) or
         byte_size(candidate) > 1_000)
  end

  defp restore_decimals(value, marker) when is_binary(value) do
    case value do
      ^marker <> number -> decimal_from_lexeme(number)
      value -> value
    end
  end

  defp restore_decimals(value, marker) when is_map(value) do
    Map.new(value, fn {key, nested} -> {key, restore_decimals(nested, marker)} end)
  end

  defp restore_decimals(value, marker) when is_list(value),
    do: Enum.map(value, &restore_decimals(&1, marker))

  defp restore_decimals(value, _marker), do: value

  defp decimal_from_lexeme(number) do
    %{"integer" => integer, "fraction" => fraction, "exponent" => exponent} =
      Regex.named_captures(@number, number)

    digits = String.trim_leading(integer <> fraction, "0")
    coefficient = if digits == "", do: 0, else: String.to_integer(digits)

    %Decimal{
      sign: if(String.starts_with?(number, "-"), do: -1, else: 1),
      coef: coefficient,
      exp: bounded_exponent(exponent) - byte_size(fraction)
    }
  end

  defp bounded_exponent(""), do: 0

  defp bounded_exponent(exponent) do
    {sign, digits} =
      case exponent do
        "+" <> digits -> {1, digits}
        "-" <> digits -> {-1, digits}
        digits -> {1, digits}
      end

    digits = String.trim_leading(digits, "0")
    digits = if digits == "", do: "0", else: digits

    if byte_size(digits) > 6 do
      sign * 1_000_000
    else
      sign * String.to_integer(digits)
    end
  end
end
