defmodule RengaWeb.InventoryOperationsLiveTest do
  use RengaWeb.ConnCase, async: true

  import Ecto.Query
  import Phoenix.LiveViewTest
  import Renga.AccountsFixtures
  import Renga.InventoryFixtures

  alias Renga.Accounts
  alias Renga.Inventory
  alias Renga.Inventory.AgentLease
  alias Renga.Repo

  @installation_id "67e55044-10b1-426f-9247-bb680e5fe0c8"

  setup %{conn: conn} do
    user = user_fixture()
    organization = organization_fixture()
    membership = organization_membership_fixture(user, organization, %{role: "admin"})
    scope = Accounts.scope_for_user(user, organization.id)

    conn =
      conn
      |> log_in_user(user)
      |> put_session(:current_organization_id, organization.id)

    {:ok, {key, token}} = Inventory.create_intake_api_key(scope, %{name: "Existing fleet"})
    {:ok, authenticated_key} = Inventory.authenticate_intake_api_key(token)

    {:ok, {agent, _lease}} =
      Inventory.record_intake_agent_check_in(scope, authenticated_key, @installation_id, %{
        capabilities: ["host.inventory"],
        metadata: %{"agent_version" => "0.1.0"}
      })

    source = Inventory.get_source!(scope, agent.source_id)

    %{
      conn: conn,
      scope: scope,
      membership: membership,
      key: key,
      source: source,
      agent: agent
    }
  end

  test "shows organization keys separately from automatically discovered collectors", %{
    conn: conn,
    key: key,
    source: source
  } do
    {:ok, view, _html} = live(conn, ~p"/inventory/operations")

    assert has_element?(view, "#intake-key-management")
    assert has_element?(view, "#intake-key-#{key.id}", "Existing fleet")
    assert has_element?(view, "#collector-list")
    assert has_element?(view, "#collector-#{source.id}", "Connected")
    assert has_element?(view, "#collector-#{source.id}", "67e55044…e0c8")
    refute has_element?(view, "#collector-#{source.id}", "Credential")
    refute has_element?(view, "[id^='rotate-collector-']")
  end

  test "creates and reveals an intake key once", %{conn: conn, scope: scope} do
    {:ok, view, _html} = live(conn, ~p"/inventory/operations")

    view |> element("#new-intake-key-button") |> render_click()
    assert has_element?(view, "#new-intake-key-panel")

    view
    |> form("#new-intake-key-form", intake_api_key: %{name: "Replacement fleet"})
    |> render_submit()

    assert has_element?(view, "#intake-key-credentials")
    assert has_element?(view, "#issued-intake-key", "renga_intake_")

    assert has_element?(
             view,
             "#copy-intake-key[phx-hook='CopyToClipboard'][data-copy-target='#issued-intake-key']"
           )

    assert has_element?(
             view,
             "#intake-key-credentials code",
             ~s(renga_url = "http://localhost:4002")
           )

    assert has_element?(view, "#intake-key-credentials code", ~s(intake_api_key = "renga_intake_))
    refute has_element?(view, "#intake-key-credentials code", "@issued_token")

    assert has_element?(
             view,
             "#intake-key-credentials code > span:first-child",
             ~s(renga_url = "http://localhost:4002")
           )

    assert has_element?(
             view,
             "#intake-key-credentials code > span:nth-child(2)",
             ~s(intake_api_key = "renga_intake_)
           )

    assert has_element?(view, "#intake-api-keys", "Replacement fleet")
    assert Enum.any?(Inventory.list_intake_api_keys(scope), &(&1.name == "Replacement fleet"))

    view |> element("#finish-intake-key-setup") |> render_click()
    refute has_element?(view, "#issued-intake-key")
  end

  test "revokes one key without deleting collector provenance", %{
    conn: conn,
    scope: scope,
    key: key,
    source: source,
    agent: agent
  } do
    {:ok, view, _html} = live(conn, ~p"/inventory/operations")
    view |> element("#revoke-intake-key-#{key.id}") |> render_click()

    assert has_element?(view, "#intake-key-#{key.id}", "Revoked")
    refute has_element?(view, "#revoke-intake-key-#{key.id}")
    assert Inventory.get_source!(scope, source.id)
    assert Inventory.get_agent!(scope, agent.id)
  end

  test "viewer sees operations but cannot forge key mutations" do
    viewer = user_fixture()
    organization = organization_fixture(%{name: "Read only operations"})
    organization_membership_fixture(viewer, organization, %{role: "viewer"})
    scope = Accounts.scope_for_user(viewer, organization.id)

    conn =
      build_conn()
      |> log_in_user(viewer)
      |> put_session(:current_organization_id, organization.id)

    {:ok, view, _html} = live(conn, ~p"/inventory/operations")
    refute has_element?(view, "#new-intake-key-button")

    render_hook(view, "create_intake_key", %{"intake_api_key" => %{"name" => "Forged"}})
    assert Inventory.list_intake_api_keys(scope) == []
  end

  test "a stale admin scope cannot create or revoke keys after role downgrade", %{
    conn: conn,
    scope: scope,
    membership: membership,
    key: key
  } do
    {:ok, view, _html} = live(conn, ~p"/inventory/operations")
    {:ok, _membership} = Accounts.update_organization_membership(membership, %{role: "viewer"})

    render_hook(view, "create_intake_key", %{"intake_api_key" => %{"name" => "Forged"}})
    render_hook(view, "revoke_intake_key", %{"id" => key.id})

    assert Enum.map(Inventory.list_intake_api_keys(scope), &{&1.name, &1.status}) == [
             {"Existing fleet", "active"}
           ]
  end

  test "disconnected filter follows lease state", %{conn: conn, source: source, agent: agent} do
    expired_at = DateTime.add(Renga.Time.utc_now_ms(), -1, :second)

    Repo.update_all(
      from(lease in AgentLease, where: lease.agent_id == ^agent.id),
      set: [renewed_at: DateTime.add(expired_at, -90, :second), expires_at: expired_at]
    )

    {:ok, view, _html} = live(conn, ~p"/inventory/operations?disconnected=true")
    assert has_element?(view, "#collector-#{source.id}", "Disconnected")
  end

  test "does not display keys or collectors from another organization", %{conn: conn} do
    other_user = user_fixture()
    organization = organization_fixture(%{name: "Other operations"})
    organization_membership_fixture(other_user, organization, %{role: "admin"})
    other_scope = Accounts.scope_for_user(other_user, organization.id)
    {:ok, {foreign_key, _token}} = Inventory.create_intake_api_key(other_scope, %{name: "Secret"})

    {:ok, view, _html} = live(conn, ~p"/inventory/operations")
    refute has_element?(view, "#intake-key-#{foreign_key.id}")
    refute has_element?(view, "#intake-api-keys", "Secret")
  end
end
