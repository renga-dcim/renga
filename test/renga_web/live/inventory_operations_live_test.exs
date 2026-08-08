defmodule RengaWeb.InventoryOperationsLiveTest do
  use RengaWeb.ConnCase, async: true

  import Ecto.Query
  import Phoenix.LiveViewTest
  import Renga.AccountsFixtures
  import Renga.InventoryFixtures

  alias Renga.Inventory
  alias Renga.Inventory.AgentLease
  alias Renga.Repo

  @connected_installation_id "67e55044-10b1-426f-9247-bb680e5fe0c8"
  @disconnected_installation_id "8ea9ae04-bf9b-4c34-8192-4f617eade95e"

  setup %{conn: conn} do
    user = user_fixture()
    organization = organization_fixture()
    membership = organization_membership_fixture(user, organization, %{role: "admin"})
    scope = Renga.Accounts.scope_for_user(user, organization.id)

    conn =
      conn
      |> log_in_user(user)
      |> put_session(:current_organization_id, organization.id)

    {:ok, {connected_source, connected_token}} =
      Inventory.create_source_with_token(scope, %{kind: "host_agent", name: "connected-source"})

    {:ok, {disconnected_source, _token}} =
      Inventory.create_source_with_token(scope, %{
        kind: "host_agent",
        name: "disconnected-source"
      })

    {:ok, {connected_agent, _lease}} =
      Inventory.record_agent_check_in(scope, connected_source.id, %{
        name: "edge-01",
        installation_id: @connected_installation_id,
        capabilities: ["host.inventory", "host.network"],
        metadata: %{"agent_version" => "0.1.0"}
      })

    {:ok, {disconnected_agent, _lease}} =
      Inventory.record_agent_check_in(scope, disconnected_source.id, %{
        name: "edge-02",
        installation_id: @disconnected_installation_id,
        checked_in_at: ~U[2026-08-01 00:00:00.000000Z]
      })

    {:ok, observation} =
      Inventory.create_observation(scope, connected_source.id, %{
        observation_id: "operations-live-report",
        observed_at: ~U[2026-08-07 11:30:00.000000Z],
        payload: %{"hostname" => "edge-01"}
      })

    {:ok, resource} =
      Inventory.create_resource(scope, %{kind: "server", name: "edge-01"})

    {:ok, identifier} =
      Inventory.create_resource_identifier(scope, resource.id, %{
        kind: "hostname",
        value: "edge-01"
      })

    {:ok, _claim} =
      Inventory.create_resource_identifier_claim(scope, connected_source.id, observation.id, %{
        resource_id: resource.id,
        resource_identifier_id: identifier.id,
        kind: "hostname",
        value: "edge-01"
      })

    %{
      conn: conn,
      scope: scope,
      membership: membership,
      connected_source: connected_source,
      connected_token: connected_token,
      connected_agent: connected_agent,
      disconnected_agent: disconnected_agent,
      resource: resource,
      observation: observation
    }
  end

  test "combines credential and runtime state into one collector row", %{
    conn: conn,
    connected_source: source,
    connected_agent: _agent,
    resource: resource
  } do
    {:ok, view, _html} = live(conn, ~p"/inventory/operations")

    assert has_element?(view, "#collector-list")
    assert has_element?(view, "#collector-filters")
    assert has_element?(view, "#collectors")
    assert has_element?(view, "#collector-#{source.id}", "Connected")
    assert has_element?(view, "#collector-#{source.id}", "Credential active")
    assert has_element?(view, "#collector-#{source.id}", "67e55044…e0c8")
    assert has_element?(view, "#collector-#{source.id}", "host.inventory")
    assert has_element?(view, "#collector-#{source.id}", "2026-08-07 11:30 UTC")

    assert has_element?(
             view,
             "#collector-#{source.id} a[href='/inventory/resources/#{resource.id}']"
           )

    refute has_element?(view, "#sources")
    refute has_element?(view, "#agents")
  end

  test "filters to disconnected agents", %{
    conn: conn,
    connected_agent: connected,
    disconnected_agent: disconnected
  } do
    {:ok, view, _html} = live(conn, ~p"/inventory/operations?disconnected=true")

    assert has_element?(view, "#collector-#{disconnected.source_id}", "Disconnected")
    refute has_element?(view, "#collector-#{connected.source_id}")
  end

  test "does not expose sources or agents from another organization", %{conn: conn} do
    other_organization = organization_fixture(%{name: "Other Operations"})
    other_scope = Renga.Accounts.scope_for(other_organization)

    {:ok, foreign_source} =
      Inventory.create_source(other_scope, %{kind: "host_agent", name: "secret-source"})

    {:ok, {foreign_agent, _lease}} =
      Inventory.record_agent_check_in(other_scope, foreign_source.id)

    {:ok, view, _html} = live(conn, ~p"/inventory/operations")

    refute has_element?(view, "#collector-#{foreign_source.id}")
    refute has_element?(view, "#collector-#{foreign_agent.source_id}")
  end

  test "refreshes the disconnected filter when a lease expires", %{
    conn: conn,
    connected_agent: agent
  } do
    {:ok, view, _html} = live(conn, ~p"/inventory/operations?disconnected=true")
    refute has_element?(view, "#collector-#{agent.source_id}")

    expired_at = DateTime.add(Renga.Time.utc_now_ms(), -1, :second)

    Repo.update_all(
      from(lease in AgentLease, where: lease.agent_id == ^agent.id),
      set: [renewed_at: DateTime.add(expired_at, -90, :second), expires_at: expired_at]
    )

    send(view.pid, :refresh)

    assert has_element?(view, "#collector-#{agent.source_id}", "Disconnected")
  end

  test "creates a collector and reveals one-time setup credentials", %{conn: conn, scope: scope} do
    {:ok, view, _html} = live(conn, ~p"/inventory/operations")

    view |> element("#new-collector-button") |> render_click()
    assert has_element?(view, "#new-collector-panel")
    assert has_element?(view, "#new-collector-form")

    view
    |> form("#new-collector-form", collector: %{name: "lab-agent"})
    |> render_submit()

    assert has_element?(view, "#collector-credentials")
    assert has_element?(view, "#issued-collector-token", "renga_src_")
    assert has_element?(view, "#issued-installation-id")

    source = Enum.find(Inventory.list_sources(scope), &(&1.name == "lab-agent"))
    assert has_element?(view, "#collector-#{source.id}", "Awaiting enrollment")
  end

  test "rotates a credential without changing its installation binding", %{
    conn: conn,
    scope: scope,
    connected_source: source,
    connected_agent: agent,
    connected_token: old_token
  } do
    {:ok, view, _html} = live(conn, ~p"/inventory/operations")

    view |> element("#rotate-collector-#{source.id}") |> render_click()

    assert has_element?(view, "#collector-credentials", "Credential rotated")
    assert has_element?(view, "#issued-installation-id", @connected_installation_id)
    assert :error = Inventory.authenticate_source_token(old_token)
    assert Inventory.get_agent!(scope, agent.id).installation_id == @connected_installation_id
  end

  test "resets enrollment while retaining the collector source", %{
    conn: conn,
    scope: scope,
    connected_source: source,
    connected_token: old_token,
    resource: resource,
    observation: observation
  } do
    {:ok, view, _html} = live(conn, ~p"/inventory/operations")

    view |> element("#reset-collector-#{source.id}") |> render_click()

    assert has_element?(view, "#collector-credentials", "Enrollment reset")
    assert has_element?(view, "#collector-#{source.id}", "Awaiting enrollment")

    new_token =
      view
      |> element("#issued-collector-token")
      |> render()
      |> LazyHTML.from_fragment()
      |> LazyHTML.text()
      |> String.trim()

    assert String.starts_with?(new_token, "renga_src_")
    assert byte_size(new_token) == 53
    assert :error = Inventory.authenticate_source_token(old_token)
    assert {:ok, _source} = Inventory.authenticate_source_token(new_token)
    refute Enum.any?(Inventory.list_agents(scope), &(&1.source_id == source.id))
    assert Inventory.get_source!(scope, source.id)
    assert Enum.any?(Inventory.list_observations(scope), &(&1.id == observation.id))
    assert Inventory.get_resource!(scope, resource.id)
    assert Inventory.list_resource_identifier_claims(scope, resource.id) != []
  end

  test "viewer cannot forge collector credential mutations" do
    user = user_fixture()
    organization = organization_fixture(%{name: "Read only operations"})
    organization_membership_fixture(user, organization, %{role: "viewer"})
    scope = Renga.Accounts.scope_for_user(user, organization.id)

    conn =
      build_conn()
      |> log_in_user(user)
      |> put_session(:current_organization_id, organization.id)

    {:ok, {source, _token}} =
      Inventory.create_source_with_token(scope, %{kind: "host_agent", name: "read-only-agent"})

    original_source = Inventory.get_source!(scope, source.id)
    {:ok, view, _html} = live(conn, ~p"/inventory/operations")

    refute has_element?(view, "#new-collector-button")
    refute has_element?(view, "#rotate-collector-#{source.id}")

    render_hook(view, "create_collector", %{"collector" => %{"name" => "forged-agent"}})
    render_hook(view, "rotate_collector", %{"id" => source.id})
    render_hook(view, "reset_collector", %{"id" => source.id})
    render_hook(view, "revoke_collector", %{"id" => source.id})

    current_source = Inventory.get_source!(scope, source.id)
    assert current_source.status == original_source.status
    assert current_source.token_hash == original_source.token_hash
    refute Enum.any?(Inventory.list_sources(scope), &(&1.name == "forged-agent"))
  end

  for membership_change <- [%{role: "viewer"}, %{status: "disabled"}] do
    test "cached admin scope cannot mutate collectors after membership changes to #{inspect(membership_change)}",
         %{
           conn: conn,
           scope: scope,
           membership: membership,
           connected_source: source,
           connected_agent: agent
         } do
      {:ok, view, _html} = live(conn, ~p"/inventory/operations")
      original_source = Inventory.get_source!(scope, source.id)
      original_source_count = length(Inventory.list_sources(scope))

      assert {:ok, _membership} =
               Renga.Accounts.update_organization_membership(
                 membership,
                 unquote(Macro.escape(membership_change))
               )

      render_hook(view, "create_collector", %{"collector" => %{"name" => "stale-admin-agent"}})
      render_hook(view, "rotate_collector", %{"id" => source.id})
      render_hook(view, "reset_collector", %{"id" => source.id})
      render_hook(view, "revoke_collector", %{"id" => source.id})

      current_source = Inventory.get_source!(scope, source.id)
      assert current_source.status == original_source.status
      assert current_source.token_hash == original_source.token_hash
      assert length(Inventory.list_sources(scope)) == original_source_count
      assert Inventory.get_agent!(scope, agent.id).id == agent.id
    end
  end

  test "crafted collector events cannot mutate another source kind", %{
    conn: conn,
    scope: scope
  } do
    {:ok, {manual_source, _token}} =
      Inventory.create_source_with_token(scope, %{kind: "manual", name: "manual-import"})

    original_source = Inventory.get_source!(scope, manual_source.id)
    {:ok, view, _html} = live(conn, ~p"/inventory/operations")

    render_hook(view, "rotate_collector", %{"id" => manual_source.id})
    render_hook(view, "reset_collector", %{"id" => manual_source.id})
    render_hook(view, "revoke_collector", %{"id" => manual_source.id})

    current_source = Inventory.get_source!(scope, manual_source.id)
    assert current_source.status == original_source.status
    assert current_source.token_hash == original_source.token_hash
  end
end
