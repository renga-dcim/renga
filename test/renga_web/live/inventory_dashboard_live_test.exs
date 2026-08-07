defmodule RengaWeb.InventoryDashboardLiveTest do
  use RengaWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Renga.AccountsFixtures
  import Renga.InventoryFixtures

  alias Renga.Inventory

  setup %{conn: conn} do
    user = user_fixture()
    organization = organization_fixture()
    organization_membership_fixture(user, organization)
    scope = Renga.Accounts.scope_for_user(user, organization.id)

    conn =
      conn
      |> log_in_user(user)
      |> put_session(:current_organization_id, organization.id)

    %{conn: conn, scope: scope}
  end

  test "renders organization-scoped lifecycle, freshness, and connectivity counts", %{
    conn: conn,
    scope: scope
  } do
    {:ok, resource} =
      Inventory.create_resource(scope, %{
        kind: "server",
        name: "edge-01",
        lifecycle_state: "active"
      })

    {:ok, _condition} =
      Inventory.put_resource_condition(scope, resource.id, %{
        type: "InventoryCurrent",
        status: "false",
        reason: "ObservationExpired"
      })

    {:ok, source} =
      Inventory.create_source(scope, %{kind: "host_agent", name: "edge-agent"})

    {:ok, {_agent, _lease}} = Inventory.record_agent_check_in(scope, source.id)

    {:ok, view, _html} = live(conn, ~p"/inventory")

    assert has_element?(view, "#inventory-dashboard")
    assert has_element?(view, "#resource-count", "1")
    assert has_element?(view, "#inventory-current-count", "0")
    assert has_element?(view, "#agent-connected-count", "1")
    assert has_element?(view, "#attention-count", "1")
    assert has_element?(view, "#lifecycle-breakdown")
    assert has_element?(view, "#health-breakdown")
  end

  test "does not expose inventory from another organization", %{conn: conn} do
    other_organization = organization_fixture(%{name: "Other Operations"})
    other_scope = Renga.Accounts.scope_for(other_organization)

    {:ok, _resource} =
      Inventory.create_resource(other_scope, %{kind: "server", name: "secret-host"})

    {:ok, view, _html} = live(conn, ~p"/inventory")

    assert has_element?(view, "#resource-count", "0")
    refute has_element?(view, "#inventory-dashboard", "secret-host")
  end

  test "redirects unauthenticated users", %{conn: conn} do
    conn = conn |> recycle() |> init_test_session(%{})

    assert {:error, {:redirect, %{to: "/users/log-in"}}} = live(conn, ~p"/inventory")
  end

  test "requires a selected organization", %{conn: conn} do
    conn = delete_session(conn, :current_organization_id)

    assert {:error, {:redirect, %{to: "/", flash: flash}}} = live(conn, ~p"/inventory")
    assert flash["error"] == "Select an organization to view inventory."
  end
end
