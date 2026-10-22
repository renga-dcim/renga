defmodule Renga.Scim.Filter do
  @moduledoc """
  The list filters Renga supports (RFD 16, "Endpoints"): one comparison of
  the form `attribute eq "value"`, which is what the major providers send.
  The attribute and operator are matched without case.
  """

  @comparison ~r/^\s*(?<attribute>[A-Za-z][A-Za-z0-9._:-]*)\s+eq\s+"(?<value>(?:[^"\\]|\\.)*)"\s*$/i

  @doc """
  Parses `filter` against `attributes`, a map from SCIM attribute name to
  the field it compares. Returns `{:ok, {field, value}}` or
  `{:error, detail}`.
  """
  def parse(filter, attributes) when is_binary(filter) do
    with %{"attribute" => attribute, "value" => value} <-
           Regex.named_captures(@comparison, filter),
         {:ok, field} <- field(attribute, attributes) do
      {:ok, {field, unescape(value)}}
    else
      {:error, detail} -> {:error, detail}
      nil -> {:error, ~s(Only filters of the form attribute eq "value" are supported)}
    end
  end

  defp field(attribute, attributes) do
    # A fully qualified name such as
    # urn:ietf:params:scim:schemas:core:2.0:User:userName names the same
    # attribute.
    short = attribute |> String.split(":") |> List.last() |> String.downcase()

    Enum.find_value(attributes, fn {name, field} ->
      if String.downcase(name) == short, do: {:ok, field}
    end) || {:error, "Filtering on #{attribute} is not supported"}
  end

  defp unescape(value), do: Regex.replace(~r/\\(.)/, value, "\\1")
end
