defmodule RengaWeb.InventoryQueryTest do
  use ExUnit.Case, async: true

  alias RengaWeb.InventoryQuery

  test "the plain list has no query params" do
    assert %{} == %{} |> InventoryQuery.parse() |> InventoryQuery.to_params()
  end

  test "round-trips every setting through the URL" do
    params = %{
      "q" => "compute",
      "kind" => "server,switch",
      "lifecycle" => "active",
      "freshness" => "stale",
      "source" => "6f1c2b8e-4f7a-4d0e-9a52-0f3c1e8d2a41",
      "group" => "kind",
      "sort" => "-last_seen",
      "cols" => "kind,status",
      "page" => "3",
      "sel" => "a,b"
    }

    query = InventoryQuery.parse(params)

    assert query.kinds == ["server", "switch"]
    assert query.group == :kind
    assert query.sort == {:last_seen, :desc}
    assert query.columns == ["kind", "status"]
    assert query.page == 3
    assert query.selected == ["a", "b"]
    assert InventoryQuery.to_params(query) == params
  end

  test "views keep filters and display but not page or selection" do
    query = InventoryQuery.parse(%{"freshness" => "stale", "page" => "2", "sel" => "a"})

    assert InventoryQuery.view_params(query) == %{"freshness" => "stale"}
  end

  test "reads the old stale=true bookmark as stale freshness" do
    assert %{freshness: "stale"} = InventoryQuery.parse(%{"stale" => "true"})

    assert InventoryQuery.parse(%{"stale" => "true"}) |> InventoryQuery.to_params() == %{
             "freshness" => "stale"
           }
  end

  test "falls back to defaults for malformed or unknown values" do
    query =
      InventoryQuery.parse(%{
        "lifecycle" => "exploded",
        "freshness" => "soon",
        "group" => "owner",
        "sort" => "-colour",
        "page" => "-4",
        "cols" => "kind,secret"
      })

    assert query.lifecycle == nil
    assert query.freshness == nil
    assert query.group == nil
    assert query.sort == {:name, :desc}
    assert query.page == 1
    assert query.columns == ["kind"]
  end

  test "keeps columns in canonical order and remembers hiding them all" do
    assert InventoryQuery.parse(%{"cols" => "seen,kind"}).columns == ["kind", "seen"]

    none = %{InventoryQuery.parse(%{}) | columns: []}
    assert InventoryQuery.to_params(none) == %{"cols" => "none"}
    assert InventoryQuery.parse(%{"cols" => "none"}).columns == []
  end
end
