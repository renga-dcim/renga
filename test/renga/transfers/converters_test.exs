defmodule Renga.Transfers.ConvertersTest do
  use ExUnit.Case, async: true

  alias Renga.Transfers.Converters

  defmodule RenameField do
    def convert("racks", record),
      do: record |> Map.put("label", record["name"]) |> Map.delete("name")

    def convert(_type, record), do: record
    def added_types, do: []
  end

  defmodule AddField do
    def convert("racks", record), do: Map.put(record, "height", 42)
    def convert(_type, record), do: record
    def added_types, do: ["rack_faces"]
  end

  @converters %{1 => RenameField, 2 => AddField}

  test "chains the converters from a version to the current one, in order" do
    assert Converters.chain(3, 3, @converters) == {:ok, []}
    assert Converters.chain(1, 3, @converters) == {:ok, [RenameField, AddField]}
    assert Converters.chain(2, 3, @converters) == {:ok, [AddField]}

    # A gap, or a version from the future, has no chain.
    assert Converters.chain(1, 4, @converters) == :error
    assert Converters.chain(0, 3, @converters) == :error
    assert Converters.chain(4, 3, @converters) == :error
  end

  test "a record passes through each converter, and each names the types it adds" do
    {:ok, chain} = Converters.chain(1, 3, @converters)

    assert Converters.convert(%{"id" => "r", "name" => "A1"}, "racks", chain) ==
             %{"id" => "r", "label" => "A1", "height" => 42}

    assert Converters.convert(%{"id" => "s"}, "sites", chain) == %{"id" => "s"}
    assert Converters.added_types(chain) == ["rack_faces"]
  end
end
