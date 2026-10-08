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

  describe "selection" do
    test "lives in the URL and shows the floating bar", %{
      conn: conn,
      server: server,
      switch: switch
    } do
      {:ok, view, _html} = live(conn, ~p"/inventory")
      refute has_element?(view, "#bulk-bar")

      view |> element("#resources-#{server.id} [data-list-check]") |> render_click()
      assert_patch(view, ~p"/inventory?sel=#{server.id}")
      assert has_element?(view, "#bulk-count", "1 resource selected")
      assert has_element?(view, "#resources-#{server.id} [data-list-check][checked]")

      view |> element("#resources-check-all") |> render_click()
      assert has_element?(view, "#bulk-count", "2 resources selected")
      assert has_element?(view, "#resources-#{switch.id} [data-list-check][checked]")

      view |> element("#resources-check-all") |> render_click()
      refute has_element?(view, "#bulk-bar")

      view |> element("#resources-#{switch.id} [data-list-check]") |> render_click()
      view |> element("#bulk-clear") |> render_click()
      assert_patch(view, ~p"/inventory")
    end

    test "sets lifecycle on every selected resource after confirming", %{
      conn: conn,
      scope: scope,
      server: server,
      switch: switch
    } do
      {:ok, view, _html} = live(conn, ~p"/inventory?#{%{"sel" => "#{server.id},#{switch.id}"}}")

      assert has_element?(view, "#bulk-lifecycle-retired", "Set 2 resources to Retired?")
      view |> element("#bulk-lifecycle-retired-confirm") |> render_click()

      assert_patch(view, ~p"/inventory")
      assert has_element?(view, "#flash-info", "Set 2 resources to retired")
      assert Inventory.get_resource!(scope, server.id).lifecycle_state == "retired"
      assert Inventory.get_resource!(scope, switch.id).lifecycle_state == "retired"
    end

    test "explains why members cannot change lifecycle", %{
      conn: conn,
      scope: scope,
      server: server
    } do
      viewer = user_fixture()

      organization_membership_fixture(
        viewer,
        %Renga.Accounts.Organization{id: scope.organization_id},
        %{
          role: "viewer"
        }
      )

      conn =
        conn
        |> log_in_user(viewer)
        |> put_session(:current_organization_id, scope.organization_id)

      {:ok, view, _html} = live(conn, ~p"/inventory?sel=#{server.id}")

      assert has_element?(view, "#bulk-lifecycle-unavailable", "Requires the owner or admin role")
      refute has_element?(view, "#bulk-lifecycle-retired")

      render_hook(view, "bulk_lifecycle", %{"state" => "retired"})
      assert has_element?(view, "#flash-error", "not allowed")
      refute Inventory.get_resource!(scope, server.id).lifecycle_state == "retired"
    end
  end
end
