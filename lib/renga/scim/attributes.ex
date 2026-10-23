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
        fetch_insensitive(map, String.downcase(name))
    end
  end

  def fetch(_map, _name), do: :error

  defp fetch_insensitive(map, wanted) do
    Enum.find_value(map, :error, fn {key, value} ->
      if is_binary(key) and String.downcase(key) == wanted, do: {:ok, value}
    end)
  end

  @doc "Like `fetch/2`, with `default` when the attribute is absent."
  def get(map, name, default \\ nil) do
    case fetch(map, name) do
      {:ok, value} -> value
      :error -> default
    end
  end

  @doc """
  A PATCH operation's `op`, in lower case, as Entra sends `Replace`. Returns
  `{:ok, op}` or a SCIM `invalidSyntax` error.
  """
  def op(operation) do
    case get(operation, "op") do
      op when is_binary(op) and op != "" -> check_op(String.downcase(op))
      _other -> check_op(nil)
    end
  end

  defp check_op(op) when op in ["add", "replace", "remove"], do: {:ok, op}

  defp check_op(_op),
    do: {:error, {:invalid_syntax, "Each operation's op must be add, replace, or remove"}}

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
