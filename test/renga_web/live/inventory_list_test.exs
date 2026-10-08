defmodule RengaWeb.InventoryListTest do
  use RengaWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Renga.AccountsFixtures
  import Renga.InventoryFixtures

  alias Renga.Inventory

  setup %{conn: conn} do
    user = user_fixture()
    organization = organization_fixture()
    organization_membership_fixture(user, organization, %{role: "admin"})
    scope = Renga.Accounts.scope_for_user(user, organization.id)

    conn =
      conn
      |> log_in_user(user)
      |> put_session(:current_organization_id, organization.id)

    {:ok, source} = Inventory.create_source(scope, %{kind: "host_agent", name: "rack-agent"})

    server =
      resource!(scope, %{kind: "server", name: "compute-01", display_name: "Primary compute"})

    {:ok, _host} =
      Inventory.create_host(scope, server.id, %{
        hostname: "compute-01",
        vendor: "Acme",
        model: "DenseBox"
      })

    claim!(scope, source, server, "SN-123", ~U[2026-08-07 10:00:00.000000Z])
    condition!(scope, server, "InventoryCurrent", "false")

    switch = resource!(scope, %{kind: "switch", name: "tor-01", lifecycle_state: "inactive"})
    condition!(scope, switch, "InventoryCurrent", "true")

    %{conn: conn, scope: scope, source: source, server: server, switch: switch}
  end

  defp resource!(scope, attrs) do
    {:ok, resource} = Inventory.create_resource(scope, attrs)
    resource
  end

  defp condition!(scope, resource, type, status) do
    {:ok, _condition} =
      Inventory.put_resource_condition(scope, resource.id, %{type: type, status: status})
  end

  defp claim!(scope, source, resource, serial, observed_at) do
    {:ok, identifier} =
      Inventory.create_resource_identifier(scope, resource.id, %{
        kind: "serial_number",
        value: serial
      })

    {:ok, observation} =
      Inventory.create_observation(scope, source.id, %{
        observation_id: "list-#{serial}",
        observed_at: observed_at,
        payload: %{}
      })

    {:ok, _claim} =
      Inventory.create_resource_identifier_claim(scope, source.id, observation.id, %{
        resource_id: resource.id,
        resource_identifier_id: identifier.id,
        kind: "serial_number",
        value: serial,
        confidence: 100
      })
  end

  defp row_ids(view) do
    view
    |> render()
    |> LazyHTML.from_document()
    |> LazyHTML.query("#resources tr[data-list-row]")
    |> LazyHTML.attribute("id")
  end

  test "rows show identity, hardware, the status strip, sources, and when last seen", %{
    conn: conn,
    server: server
  } do
    {:ok, view, _html} = live(conn, ~p"/inventory")

    row = "#resources-#{server.id}"
    assert has_element?(view, "#resource-count", "2")
    assert has_element?(view, "#{row} a[href='/inventory/#{server.id}']", "Primary compute")
    assert has_element?(view, row, "compute-01")
    assert has_element?(view, row, "Acme DenseBox")
    assert has_element?(view, "#{row} [data-signal='freshness'] .text-warn-text")
    assert has_element?(view, "#{row} [data-signal='agent']", "No agent")
    assert has_element?(view, row, "rack-agent")
    assert has_element?(view, "#{row} time[title='2026-08-07 10:00 UTC']")
  end

  test "search, filters, and chips all live in the URL", %{
    conn: conn,
    server: server,
    switch: switch
  } do
    {:ok, view, _html} = live(conn, ~p"/inventory")

    view |> form("#resource-search", %{"q" => "compute"}) |> render_change()
    assert_patch(view, ~p"/inventory?q=compute")
    assert row_ids(view) == ["resources-#{server.id}"]

    view |> form("#resource-search", %{"q" => ""}) |> render_change()

    view
    |> form("#filter-form", %{"filter" => %{"kinds" => ["switch"], "lifecycle" => "inactive"}})
    |> render_change()

    assert_patch(view, ~p"/inventory?kind=switch&lifecycle=inactive")
    assert row_ids(view) == ["resources-#{switch.id}"]
    assert has_element?(view, "#chip-kind", "switch")
    assert has_element?(view, "#chip-lifecycle", "inactive")

    view |> element("#chip-kind a") |> render_click()
    assert_patch(view, ~p"/inventory?lifecycle=inactive")
    refute has_element?(view, "#chip-kind")
  end

  test "filters by freshness, including old stale=true bookmarks", %{conn: conn, server: server} do
    {:ok, view, _html} = live(conn, ~p"/inventory?stale=true")

    assert row_ids(view) == ["resources-#{server.id}"]
    assert has_element?(view, "#chip-freshness", "Stale")
  end

  test "ignores kinds the organization does not have", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/inventory")

    view |> render_hook("filter", %{"filter" => %{"kinds" => ["server", "spaceship"]}})
    assert_patch(view, ~p"/inventory?kind=server")
  end

  test "groups rows under headers counting the whole filtered list", %{
    conn: conn,
    server: server,
    switch: switch
  } do
    {:ok, view, _html} = live(conn, ~p"/inventory?group=freshness")

    assert has_element?(view, "#resources-group-freshness-stale", "Stale")
    assert has_element?(view, "#resources-group-freshness-stale", "1")
    assert has_element?(view, "#resources-group-freshness-current", "Current")
    assert row_ids(view) == ["resources-#{server.id}", "resources-#{switch.id}"]
  end

  test "display settings choose grouping, ordering, and columns", %{
    conn: conn,
    server: server,
    switch: switch
  } do
    {:ok, view, _html} = live(conn, ~p"/inventory")

    view
    |> form("#display-form", %{
      "display" => %{
        "group" => "",
        "sort" => "name",
        "direction" => "desc",
        "columns" => ["", "kind"]
      }
    })
    |> render_change()

    assert_patch(view, ~p"/inventory?cols=kind&sort=-name")
    assert row_ids(view) == ["resources-#{switch.id}", "resources-#{server.id}"]
    assert has_element?(view, "#resources-#{server.id}", "server")
    refute has_element?(view, "#resources-#{server.id}", "Acme DenseBox")
    refute has_element?(view, "#resources-#{server.id} [data-signal]")
  end

  test "old ?selected= links open the resource page", %{conn: conn, server: server} do
    assert {:error, {:live_redirect, %{to: to}}} =
             live(conn, ~p"/inventory?selected=#{server.id}")

    assert to == ~p"/inventory/#{server.id}"
  end

  test "explains an empty filtered list and offers to clear it", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/inventory?q=nothing-matches")

    assert row_ids(view) == []
    assert has_element?(view, "#resources-empty a[href='/inventory']", "Clear filters")
  end

  test "paginates and keeps filters across pages", %{conn: conn, scope: scope} do
    for index <- 1..50 do
      resource!(scope, %{kind: "server", name: "page-#{String.pad_leading("#{index}", 3, "0")}"})
    end

    {:ok, view, _html} = live(conn, ~p"/inventory?kind=server")

    assert length(row_ids(view)) == 50
    view |> element("#resources-next") |> render_click()
    assert_patch(view, ~p"/inventory?kind=server&page=2")
    assert length(row_ids(view)) == 1
    assert has_element?(view, "#resources-previous")
  end
end
