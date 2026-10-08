defmodule RengaWeb.InventoryQuery do
  @moduledoc """
  The Inventory list's state as it lives in the URL (RFD 8: filters,
  grouping, and selection live in the URL so any view can be shared).

  `parse/1` turns query params into a struct, `to_params/1` turns it back
  into the shortest equivalent query (defaults are omitted, so the plain
  list is `/inventory`), and `list_options/1` feeds
  `Renga.Inventory.list_operational_resources/2`. Saved views store the
  output of `to_params/1`.

  Unknown or malformed values fall back to defaults instead of raising, since
  URLs are user input and old bookmarks must keep opening.
  """

  @lifecycles ~w(active inactive retired unknown)
  @freshness ~w(current stale unknown)
  @groups ~w(kind lifecycle freshness)
  @sort_fields ~w(name kind lifecycle last_seen)

  @columns ~w(kind hardware status sources seen)
  @default_columns @columns

  defstruct search: "",
            kinds: [],
            lifecycle: nil,
            freshness: nil,
            source_id: nil,
            group: nil,
            sort: {:name, :asc},
            columns: @default_columns,
            page: 1,
            selected: []

  @type t :: %__MODULE__{}

  @doc "Columns that can be shown or hidden; Name is always shown."
  def columns, do: @columns

  def lifecycles, do: @lifecycles
  def freshness_states, do: @freshness
  def groups, do: @groups
  def sort_fields, do: @sort_fields

  @doc "Parses query params into list state."
  def parse(params) when is_map(params) do
    %__MODULE__{
      search: params |> Map.get("q", "") |> to_string() |> String.trim(),
      kinds: params |> Map.get("kind") |> split_list(),
      lifecycle: member(params["lifecycle"], @lifecycles),
      # `stale=true` is the pre-RFD 8 spelling, kept for old bookmarks.
      freshness:
        member(params["freshness"], @freshness) || if(params["stale"] == "true", do: "stale"),
      source_id: blank_to_nil(params["source"]),
      group: params["group"] |> member(@groups) |> to_atom(),
      sort: parse_sort(params["sort"]),
      columns: parse_columns(params["cols"]),
      page: parse_page(params["page"]),
      selected: params |> Map.get("sel") |> split_list()
    }
  end

  @doc "Encodes list state as the shortest equivalent query params."
  def to_params(%__MODULE__{} = query) do
    [
      {"q", query.search},
      {"kind", Enum.join(query.kinds, ",")},
      {"lifecycle", query.lifecycle},
      {"freshness", query.freshness},
      {"source", query.source_id},
      {"group", query.group && Atom.to_string(query.group)},
      {"sort", encode_sort(query.sort)},
      {"cols", encode_columns(query.columns)},
      {"page", query.page > 1 && Integer.to_string(query.page)},
      {"sel", Enum.join(query.selected, ",")}
    ]
    |> Enum.reject(fn {_key, value} -> value in [nil, "", false] end)
    |> Map.new()
  end

  @doc "The params that define a view: everything except page and selection."
  def view_params(%__MODULE__{} = query) do
    query |> to_params() |> Map.drop(["page", "sel"])
  end

  @doc "Options for `Renga.Inventory.list_operational_resources/2`."
  def list_options(%__MODULE__{} = query) do
    [
      search: query.search,
      kinds: query.kinds,
      lifecycle: query.lifecycle,
      freshness: query.freshness,
      source_id: query.source_id,
      group: query.group,
      sort: query.sort,
      page: query.page
    ]
  end

  @doc "Whether any filter narrows the list."
  def filtered?(%__MODULE__{} = query) do
    query.search != "" or query.kinds != [] or
      Enum.any?([query.lifecycle, query.freshness, query.source_id])
  end

  defp parse_sort("-" <> field), do: {sort_field(field), :desc}
  defp parse_sort(field) when is_binary(field), do: {sort_field(field), :asc}
  defp parse_sort(_missing), do: {:name, :asc}

  defp sort_field(field), do: field |> member(@sort_fields) |> to_atom() || :name

  defp encode_sort({:name, :asc}), do: nil
  defp encode_sort({field, :asc}), do: Atom.to_string(field)
  defp encode_sort({field, :desc}), do: "-" <> Atom.to_string(field)

  defp parse_columns(nil), do: @default_columns

  defp parse_columns(value) do
    chosen = split_list(value)
    # Keep the canonical column order whatever order the URL lists them in.
    Enum.filter(@columns, &(&1 in chosen))
  end

  defp encode_columns(columns) when columns == @default_columns, do: nil
  defp encode_columns([]), do: "none"
  defp encode_columns(columns), do: Enum.join(columns, ",")

  defp parse_page(page) when is_binary(page) do
    case Integer.parse(page) do
      {page, ""} when page > 0 -> page
      _invalid -> 1
    end
  end

  defp parse_page(_page), do: 1

  defp split_list(value) when is_binary(value) do
    value |> String.split(",", trim: true) |> Enum.map(&String.trim/1) |> Enum.uniq()
  end

  defp split_list(_value), do: []

  defp member(value, allowed) when is_binary(value), do: if(value in allowed, do: value)
  defp member(_value, _allowed), do: nil

  # Only ever called with values already checked against a fixed list.
  defp to_atom(nil), do: nil
  defp to_atom(value), do: String.to_existing_atom(value)

  defp blank_to_nil(value) when value in [nil, ""], do: nil
  defp blank_to_nil(value), do: value
end
