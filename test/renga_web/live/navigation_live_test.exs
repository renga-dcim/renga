defmodule RengaWeb.NavigationLiveTest do
  @moduledoc """
  The sidebar, mobile menu, and command menu are generated from
  `RengaWeb.Navigation`, so they must offer the same destinations.
  """
  use RengaWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Renga.AccountsFixtures
  import Renga.InventoryFixtures

  alias RengaWeb.Navigation

  setup %{conn: conn} do
    user = user_fixture()
    organization = organization_fixture()
    organization_membership_fixture(user, organization, %{role: "admin"})

    conn =
      conn
      |> log_in_user(user)
      |> put_session(:current_organization_id, organization.id)

    %{conn: conn}
  end

  defp hrefs(view, selector) do
    view
    |> render()
    |> LazyHTML.from_document()
    |> LazyHTML.query(selector)
    |> LazyHTML.attribute("href")
  end

  test "sidebar, mobile menu, and command menu offer the same areas", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/activity")

    area_paths = Enum.map(Navigation.areas(), &Navigation.path/1)

    assert hrefs(view, "#primary-navigation a") == area_paths

    assert hrefs(view, "#app-mobile-navigation nav[aria-label='Mobile navigation'] a") ==
             area_paths

    every_section =
      for area <- [Navigation.settings() | Navigation.areas()], s <- area.sections, do: s.path

    command_paths = hrefs(view, "#command-palette a[data-command-item]")

    for path <- every_section ++ Enum.map(Navigation.views(), & &1.path) do
      assert path in command_paths, "command menu is missing #{path}"
    end
  end

  test "highlights the current area and shows its section tabs", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/network/vlans")

    assert has_element?(view, "#primary-navigation a[aria-current='page']", "Network")

    assert hrefs(view, "#area-tabs a") == [
             "/network/topology",
             "/network/vlans",
             "/network/vlan-groups",
             "/network/cables"
           ]

    assert has_element?(view, "#area-tabs a[aria-current='page'][href='/network/vlans']")
  end

  test "areas with one section show no tabs", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/inventory")

    assert has_element?(view, "#primary-navigation a[aria-current='page']", "Inventory")
    refute has_element?(view, "#area-tabs")
  end

  test "pages rendered by one LiveView land in the right area", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/inbox/placement")

    assert has_element?(view, "#primary-navigation a[aria-current='page']", "Inbox")
    assert has_element?(view, "#area-tabs a[aria-current='page'][href='/inbox/placement']")

    {:ok, view, _html} = live(conn, ~p"/places/racks")

    assert has_element?(view, "#primary-navigation a[aria-current='page']", "Places")
    assert has_element?(view, "#area-tabs a[aria-current='page'][href='/places/racks']")
  end

  test "settings pages share the Settings tabs", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/settings/collectors")

    assert has_element?(view, "#settings-link[aria-current='page']")

    assert hrefs(view, "#area-tabs a") == [
             "/settings/collectors",
             "/organizations",
             "/users/settings"
           ]
  end
end
