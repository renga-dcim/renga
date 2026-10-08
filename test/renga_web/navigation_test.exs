defmodule RengaWeb.NavigationTest do
  use ExUnit.Case, async: true

  alias RengaWeb.Navigation

  test "has the six RFD 8 areas in sidebar order, each answering one question" do
    assert Enum.map(Navigation.areas(), &{&1.label, &1.question}) == [
             {"Inbox", "What needs me?"},
             {"Inventory", "What exists?"},
             {"Places", "Where is it?"},
             {"Network", "How is it connected?"},
             {"Activity", "What changed?"},
             {"Catalog", "What can exist?"}
           ]
  end

  test "section ids are unique and locate their area" do
    ids = Navigation.section_ids()

    assert ids == Enum.uniq(ids)

    for id <- ids do
      assert {%{sections: sections}, %{id: ^id}} = Navigation.locate(id)
      assert Enum.any?(sections, &(&1.id == id))
    end

    assert {%{id: :network}, %{label: "VLANs"}} = Navigation.locate(:vlans)
    assert Navigation.locate(nil) == {nil, nil}
    assert_raise ArgumentError, ~r/unknown navigation section/, fn -> Navigation.locate(:nope) end
  end

  test "every destination is a live page, not a redirect" do
    paths =
      for(area <- [Navigation.settings() | Navigation.areas()], s <- area.sections, do: s.path) ++
        Enum.map(Navigation.views(), & &1.path)

    for path <- paths do
      %URI{path: route} = URI.parse(path)
      info = Phoenix.Router.route_info(RengaWeb.Router, "GET", route, "localhost")

      assert info.plug == Phoenix.LiveView.Plug, "#{path} should render a LiveView"
    end
  end
end
