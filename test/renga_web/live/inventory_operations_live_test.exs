defmodule RengaWeb.InventoryOperationsLiveTest do
  use RengaWeb.ConnCase, async: true

  import Ecto.Query
  import Phoenix.LiveViewTest
  import Renga.AccountsFixtures
  import Renga.InventoryFixtures

  alias Renga.Inventory
  alias Renga.Inventory.AgentLease
  alias Renga.Repo

  setup %{conn: conn} do
    user = user_fixture()
    organization = organization_fixture()
    organization_membership_fixture(user, organization)
    scope = Renga.Accounts.scope_for_user(user, organization.id)

    conn =
      conn
      |> log_in_user(user)
      |> put_session(:current_organization_id, organization.id)

    {:ok, {connected_source, _token}} =
      Inventory.create_source_with_token(scope, %{kind: "host_agent", name: "connected-source"})

    {:ok, disconnected_source} =
      Inventory.create_source(scope, %{kind: "host_agent", name: "disconnected-source"})

    {:ok, {connected_agent, _lease}} =
      Inventory.record_agent_check_in(scope, connected_source.id, %{
        name: "edge-01",
        capabilities: ["host.inventory", "host.network"],
        metadata: %{"agent_version" => "0.1.0"}
      })

    {:ok, {disconnected_agent, _lease}} =
      Inventory.record_agent_check_in(scope, disconnected_source.id, %{
        name: "edge-02",
        checked_in_at: ~U[2026-08-01 00:00:00.000000Z]
      })

    {:ok, _observation} =
      Inventory.create_observation(scope, connected_source.id, %{
        observation_id: "operations-live-report",
        observed_at: ~U[2026-08-07 11:30:00.000000Z],
        payload: %{"hostname" => "edge-01"}
      })

    %{
      conn: conn,
      scope: scope,
      connected_source: connected_source,
      connected_agent: connected_agent,
      disconnected_agent: disconnected_agent
    }
  end

  test "lists source credential state, inventory recency, leases, and capabilities", %{
    conn: conn,
    connected_source: source,
    connected_agent: agent
  } do
    {:ok, view, _html} = live(conn, ~p"/inventory/operations")

    assert has_element?(view, "#source-list")
    assert has_element?(view, "#agent-filters")
    assert has_element?(view, "#sources")
    assert has_element?(view, "#source-#{source.id}", "Issued")
    assert has_element?(view, "#source-#{source.id}", "2026-08-07 11:30 UTC")
    assert has_element?(view, "#agents-#{agent.id}", "Connected")
    assert has_element?(view, "#agents-#{agent.id}", "host.inventory")
  end

  test "filters to disconnected agents", %{
    conn: conn,
    connected_agent: connected,
    disconnected_agent: disconnected
  } do
    {:ok, view, _html} = live(conn, ~p"/inventory/operations?disconnected=true")

    assert has_element?(view, "#agents-#{disconnected.id}", "Disconnected")
    refute has_element?(view, "#agents-#{connected.id}")
  end

  test "does not expose sources or agents from another organization", %{conn: conn} do
    other_organization = organization_fixture(%{name: "Other Operations"})
    other_scope = Renga.Accounts.scope_for(other_organization)

    {:ok, foreign_source} =
      Inventory.create_source(other_scope, %{kind: "host_agent", name: "secret-source"})

    {:ok, {foreign_agent, _lease}} =
      Inventory.record_agent_check_in(other_scope, foreign_source.id)

    {:ok, view, _html} = live(conn, ~p"/inventory/operations")

    refute has_element?(view, "#source-#{foreign_source.id}")
    refute has_element?(view, "#agents-#{foreign_agent.id}")
  end

  test "refreshes the disconnected filter when a lease expires", %{
    conn: conn,
    connected_agent: agent
  } do
    {:ok, view, _html} = live(conn, ~p"/inventory/operations?disconnected=true")
    refute has_element?(view, "#agents-#{agent.id}")

    expired_at = DateTime.add(Renga.Time.utc_now_ms(), -1, :second)

    Repo.update_all(
      from(lease in AgentLease, where: lease.agent_id == ^agent.id),
      set: [renewed_at: DateTime.add(expired_at, -90, :second), expires_at: expired_at]
    )

    send(view.pid, :refresh)

    assert has_element?(view, "#agents-#{agent.id}", "Disconnected")
  end
end
