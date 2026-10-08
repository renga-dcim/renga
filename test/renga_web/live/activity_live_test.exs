defmodule RengaWeb.ActivityLiveTest do
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

    {:ok, resource} =
      Inventory.create_resource(scope, %{kind: "server", name: "compute-01", spec: %{}})

    %{conn: conn, scope: scope, resource: resource}
  end

  defp event!(scope, attrs) do
    {:ok, event} = Inventory.create_change_event(scope, attrs)
    event
  end

  defp minutes_ago(minutes), do: DateTime.add(DateTime.utc_now(), -minutes * 60)

  test "lists the organization's changes newest first", %{
    conn: conn,
    scope: scope,
    resource: resource
  } do
    older =
      event!(scope, %{resource_id: resource.id, kind: "discovered", occurred_at: minutes_ago(10)})

    newer =
      event!(scope, %{
        resource_id: resource.id,
        kind: "updated",
        field: "lifecycle_state",
        occurred_at: minutes_ago(1)
      })

    {:ok, view, _html} = live(conn, ~p"/activity")

    row_ids =
      view
      |> render()
      |> LazyHTML.from_document()
      |> LazyHTML.query("#activity-events tr[data-phx-stream]")
      |> LazyHTML.attribute("id")

    assert row_ids == ["events-#{newer.id}", "events-#{older.id}"]

    assert has_element?(view, "#events-#{newer.id}", "Updated lifecycle state")
    assert has_element?(view, "#events-#{older.id}", "Discovered")

    assert has_element?(
             view,
             "#events-#{newer.id} a[href='/inventory/#{resource.id}']",
             "compute-01"
           )

    refute has_element?(view, "#activity-load-older")
  end

  test "shows an empty state before anything changes", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/activity")

    assert has_element?(view, "#activity-events-empty")
  end

  test "never shows another organization's changes", %{conn: conn} do
    other_user = user_fixture()
    other_organization = organization_fixture()
    organization_membership_fixture(other_user, other_organization, %{role: "admin"})
    other_scope = Renga.Accounts.scope_for_user(other_user, other_organization.id)

    {:ok, other_resource} =
      Inventory.create_resource(other_scope, %{kind: "server", name: "elsewhere-01", spec: %{}})

    hidden = event!(other_scope, %{resource_id: other_resource.id, kind: "discovered"})

    {:ok, view, _html} = live(conn, ~p"/activity")

    refute has_element?(view, "#events-#{hidden.id}")
  end

  test "loads older changes a page at a time", %{conn: conn, scope: scope, resource: resource} do
    events =
      for minute <- 1..51 do
        event!(scope, %{resource_id: resource.id, kind: "stale", occurred_at: minutes_ago(minute)})
      end

    oldest = List.last(events)

    {:ok, view, _html} = live(conn, ~p"/activity")

    refute has_element?(view, "#events-#{oldest.id}")

    view |> element("#activity-load-older") |> render_click()

    assert has_element?(view, "#events-#{oldest.id}", "Marked stale")
    refute has_element?(view, "#activity-load-older")
  end

  test "adds new changes on top as they happen", %{conn: conn, scope: scope, resource: resource} do
    older =
      event!(scope, %{resource_id: resource.id, kind: "discovered", occurred_at: minutes_ago(5)})

    {:ok, view, _html} = live(conn, ~p"/activity")

    newer = event!(scope, %{resource_id: resource.id, kind: "stale"})
    Renga.Inventory.Changes.broadcast({:ok, newer}, scope.organization_id)

    row_ids =
      view
      |> render()
      |> LazyHTML.from_document()
      |> LazyHTML.query("#activity-events tr[data-phx-stream]")
      |> LazyHTML.attribute("id")

    assert row_ids == ["events-#{newer.id}", "events-#{older.id}"]
  end
end
