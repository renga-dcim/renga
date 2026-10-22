defmodule Renga.Scim.Attributes do
  @moduledoc """
  Reads SCIM attribute values the way providers send them (RFD 16,
  "Endpoints"). Attribute names are case-insensitive (RFC 7643, section
  2.1), and the strings `"true"`, `"false"`, `"True"`, and `"False"` stand
  for booleans, as Microsoft Entra ID sends them. No other string does.
  """

  @doc "The value of attribute `name` in `map`, matched without case, or `:error`."
  def fetch(map, name) when is_map(map) do
    case Map.fetch(map, name) do
      {:ok, value} ->
        {:ok, value}

      :error ->
        wanted = String.downcase(name)

        Enum.find_value(map, :error, fn {key, value} ->
          if is_binary(key) and String.downcase(key) == wanted, do: {:ok, value}
        end)
    end
  end

  def fetch(_map, _name), do: :error

  @doc "Like `fetch/2`, with `default` when the attribute is absent."
  def get(map, name, default \\ nil) do
    case fetch(map, name) do
      {:ok, value} -> value
      :error -> default
    end
  end

  @doc "A boolean, or `:error` for null and any other value."
  def boolean(value) when is_boolean(value), do: {:ok, value}
  def boolean(value) when value in ["true", "True"], do: {:ok, true}
  def boolean(value) when value in ["false", "False"], do: {:ok, false}
  def boolean(_value), do: :error

  @doc """
  An optional string: null and the empty string mean no value. Returns
  `{:ok, string_or_nil}`, or `:error` for any other type.
  """
  def optional_string(nil), do: {:ok, nil}

  def optional_string(value) when is_binary(value) do
    case String.trim(value) do
      "" -> {:ok, nil}
      trimmed -> {:ok, trimmed}
    end
  end

  def optional_string(_value), do: :error
end
