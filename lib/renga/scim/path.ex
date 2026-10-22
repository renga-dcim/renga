defmodule Renga.Scim.Path do
  @moduledoc """
  Parses a PATCH operation's `path` (RFC 7644, section 3.5.2): an attribute,
  an optional value filter in brackets, and an optional sub-attribute, as in
  `emails[type eq "work"].value` or `members[value eq "2819c223"]`. A path
  may be qualified by the resource's core schema URN. A path in any other
  schema, such as an enterprise extension Renga does not declare, parses as
  `:extension` so the operation can be accepted and its value not kept.
  """

  @path ~r/^(?<attribute>[A-Za-z$][A-Za-z0-9_$-]*)(?:\[(?<filter>[^\]]*)\])?(?:\.(?<sub>[A-Za-z$][A-Za-z0-9_$-]*))?$/

  @doc """
  Returns `{:ok, %{attribute: name, filter: filter_or_nil, sub: name_or_nil}}`
  with the names in lower case, `:extension`, or `:error`.
  """
  def parse(path, core_schema) when is_binary(path) do
    path = String.trim(path)
    prefix = String.downcase(core_schema) <> ":"

    cond do
      String.starts_with?(String.downcase(path), prefix) ->
        path
        |> binary_part(byte_size(prefix), byte_size(path) - byte_size(prefix))
        |> parse_simple()

      String.starts_with?(String.downcase(path), "urn:") ->
        :extension

      true ->
        parse_simple(path)
    end
  end

  defp parse_simple(path) do
    case Regex.named_captures(@path, path) do
      %{"attribute" => attribute, "filter" => filter, "sub" => sub} ->
        {:ok,
         %{
           attribute: String.downcase(attribute),
           filter: if(filter == "", do: nil, else: filter),
           sub: if(sub == "", do: nil, else: String.downcase(sub))
         }}

      nil ->
        :error
    end
  end
end
