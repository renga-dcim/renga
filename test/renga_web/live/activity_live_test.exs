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

  test "attributes each change to the person or source behind it", %{
    conn: conn,
    scope: scope,
    resource: resource
  } do
    {:ok, source} = Inventory.create_source(scope, %{kind: "host_agent", name: "rack-agent"})
    service = Renga.Accounts.scope_for(scope.organization)

    reported =
      event!(service, %{
        resource_id: resource.id,
        source_id: source.id,
        kind: "updated",
        field: "hostname",
        occurred_at: minutes_ago(3)
      })

    derived =
      event!(service, %{resource_id: resource.id, kind: "stale", occurred_at: minutes_ago(2)})

    assigned =
      event!(scope, %{
        resource_id: resource.id,
        kind: "finding_assigned",
        field: "component.component_drift",
        new_value: %{"assignee" => "oncall@example.com"},
        occurred_at: minutes_ago(1)
      })

    {:ok, view, _html} = live(conn, ~p"/activity")

    assert has_element?(view, "#events-#{reported.id}", "rack-agent")
    assert has_element?(view, "#events-#{derived.id}", "Renga")
    assert has_element?(view, "#events-#{assigned.id} [data-actor=person]", scope.user.email)

    assert has_element?(
             view,
             "#events-#{assigned.id}",
             "Assigned component drift to oncall@example.com"
           )
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

  test "refresh includes a burst larger than a page in an initially empty feed", %{
    conn: conn,
    scope: scope,
    resource: resource
  } do
    {:ok, view, _html} = live(conn, ~p"/activity")

    events =
      for minute <- 1..53 do
        event!(scope, %{resource_id: resource.id, kind: "stale", occurred_at: minutes_ago(minute)})
      end

    Renga.Inventory.Changes.broadcast({:ok, nil}, scope.organization_id)
    assert event_ids(view) == Enum.map(events, &"events-#{&1.id}")
    refute has_element?(view, "#activity-load-older")
  end

  test "refresh preserves loaded pages and inserts late arrivals without gaps", %{
    conn: conn,
    scope: scope,
    resource: resource
  } do
    events =
      for minute <- 1..105 do
        event!(scope, %{resource_id: resource.id, kind: "stale", occurred_at: minutes_ago(minute)})
      end

    {:ok, view, _html} = live(conn, ~p"/activity")
    view |> element("#activity-load-older") |> render_click()

    late =
      event!(scope, %{
        resource_id: resource.id,
        kind: "updated",
        occurred_at: minutes_ago(25) |> DateTime.add(30)
      })

    burst =
      for second <- 1..51 do
        event!(scope, %{
          resource_id: resource.id,
          kind: "updated",
          occurred_at: DateTime.add(~U[2030-01-01 00:00:00Z], -second)
        })
      end

    Renga.Inventory.Changes.broadcast({:ok, nil}, scope.organization_id)
    {first, rest} = Enum.split(events, 24)
    expected = burst ++ first ++ [late] ++ Enum.take(rest, 76)
    assert event_ids(view) == Enum.map(expected, &"events-#{&1.id}")
    view |> element("#activity-load-older") |> render_click()
    assert event_ids(view) == Enum.map(burst ++ first ++ [late] ++ rest, &"events-#{&1.id}")
    refute has_element?(view, "#activity-load-older")
  end

  defp event_ids(view) do
    view
    |> render()
    |> LazyHTML.from_document()
    |> LazyHTML.query("#activity-events tr[data-phx-stream]")
    |> LazyHTML.attribute("id")
  end
end
