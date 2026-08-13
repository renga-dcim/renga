defmodule RengaWeb.Api.V1.IntakeApiTest do
  use RengaWeb.ConnCase, async: true

  import Renga.AccountsFixtures
  import Renga.InventoryFixtures

  alias Renga.Accounts
  alias Renga.Inventory
  alias Renga.Repo

  @first_installation_id "67e55044-10b1-426f-9247-bb680e5fe0c8"
  @second_installation_id "8ea9ae04-bf9b-4c34-8192-4f617eade95e"

  setup do
    user = user_fixture()
    organization = organization_fixture()
    organization_membership_fixture(user, organization, %{role: "admin"})
    scope = Accounts.scope_for_user(user, organization.id)
    {:ok, {key, token}} = Inventory.create_intake_api_key(scope, %{name: "Test fleet"})

    %{scope: scope, key: key, token: token}
  end

  test "one organization key automatically registers many dedicated collectors", %{
    conn: conn,
    scope: scope,
    token: token
  } do
    first = conn |> authorize(token, @first_installation_id) |> post_check_in()
    second = build_conn() |> authorize(token, @second_installation_id) |> post_check_in()

    assert %{"status" => "accepted", "source" => %{"id" => first_source_id}} =
             json_response(first, 202)

    assert %{"status" => "accepted", "source" => %{"id" => second_source_id}} =
             json_response(second, 202)

    refute first_source_id == second_source_id

    assert Enum.sort(Enum.map(Inventory.list_agents(scope), & &1.installation_id)) ==
             Enum.sort([@first_installation_id, @second_installation_id])

    assert Enum.all?(Inventory.list_sources(scope), fn source ->
             source.kind == "host_agent" and source.token_hash == nil
           end)
  end

  test "repeated check-ins reuse the installation Source and Agent", %{
    conn: conn,
    scope: scope,
    token: token
  } do
    first = conn |> authorize(token, @first_installation_id) |> post_check_in()
    second = build_conn() |> authorize(token, @first_installation_id) |> post_check_in()

    assert %{"source" => %{"id" => source_id}, "agent" => %{"id" => agent_id}} =
             json_response(first, 202)

    assert %{"source" => %{"id" => ^source_id}, "agent" => %{"id" => ^agent_id}} =
             json_response(second, 202)

    assert length(Inventory.list_sources(scope)) == 1
    assert length(Inventory.list_agents(scope)) == 1
  end

  test "first observation registers its collector and preserves source provenance", %{
    conn: conn,
    scope: scope,
    token: token
  } do
    payload = valid_observation_payload()

    conn =
      conn
      |> authorize(token, @first_installation_id)
      |> post(~p"/api/v1/observations", payload)

    assert %{
             "status" => "accepted",
             "observation" => %{"id" => observation_id, "source_id" => source_id}
           } = json_response(conn, 202)

    [agent] = Inventory.list_agents(scope)
    assert agent.installation_id == @first_installation_id
    assert agent.source_id == source_id

    observation = Repo.get!(Renga.Inventory.Observation, observation_id)
    assert observation.source_id == agent.source_id
    assert observation.organization_id == scope.organization_id
  end

  test "the same installation UUID remains isolated between organizations", %{
    conn: conn,
    scope: scope,
    token: token
  } do
    other_user = user_fixture()
    other_organization = organization_fixture(%{name: "Other tenant"})
    organization_membership_fixture(other_user, other_organization, %{role: "admin"})
    other_scope = Accounts.scope_for_user(other_user, other_organization.id)
    {:ok, {_key, other_token}} = Inventory.create_intake_api_key(other_scope, %{name: "Other"})

    first = conn |> authorize(token, @first_installation_id) |> post_check_in()
    other = build_conn() |> authorize(other_token, @first_installation_id) |> post_check_in()

    assert %{"source" => %{"id" => first_source_id}} = json_response(first, 202)
    assert %{"source" => %{"id" => other_source_id}} = json_response(other, 202)
    refute first_source_id == other_source_id
    assert [%{installation_id: @first_installation_id}] = Inventory.list_agents(scope)
    assert [%{installation_id: @first_installation_id}] = Inventory.list_agents(other_scope)
  end

  test "revoked intake keys are rejected without deleting registered collectors", %{
    conn: conn,
    scope: scope,
    key: key,
    token: token
  } do
    accepted = conn |> authorize(token, @first_installation_id) |> post_check_in()
    assert %{"status" => "accepted"} = json_response(accepted, 202)
    assert {:ok, _key} = Inventory.revoke_intake_api_key(scope, key.id)

    rejected = build_conn() |> authorize(token, @first_installation_id) |> post_check_in()
    assert %{"errors" => [%{"path" => "authorization"}]} = json_response(rejected, 401)
    assert length(Inventory.list_agents(scope)) == 1
    assert length(Inventory.list_sources(scope)) == 1
  end

  test "requests authenticated before key revocation create no collector", %{
    scope: scope,
    key: key,
    token: token
  } do
    assert {:ok, authenticated_key} = Inventory.authenticate_intake_api_key(token)
    assert {:ok, _revoked_key} = Inventory.revoke_intake_api_key(scope, key.id)

    assert {:error, :intake_credential_changed} =
             Inventory.record_intake_agent_check_in(
               scope,
               authenticated_key,
               @first_installation_id
             )

    assert Inventory.list_sources(scope) == []
    assert Inventory.list_agents(scope) == []
  end

  test "requests authenticated before organization disable create no collector", %{
    scope: scope,
    token: token
  } do
    assert {:ok, authenticated_key} = Inventory.authenticate_intake_api_key(token)

    assert {:ok, _organization} =
             Accounts.update_organization(scope.organization, %{status: "disabled"})

    assert {:error, :intake_credential_changed} =
             Inventory.record_intake_agent_check_in(
               scope,
               authenticated_key,
               @first_installation_id
             )

    assert Inventory.list_sources(scope) == []
    assert Inventory.list_agents(scope) == []
  end

  test "legacy source-token installations retain provenance when switching to an intake key", %{
    conn: conn,
    scope: scope,
    token: intake_token
  } do
    {:ok, {legacy_source, legacy_token}} =
      Inventory.create_source_with_token(scope, %{kind: "host_agent", name: "legacy-agent"})

    legacy_conn =
      conn
      |> authorize(legacy_token, @first_installation_id)
      |> post_check_in()

    assert %{
             "source" => %{"id" => source_id},
             "agent" => %{"id" => agent_id}
           } = json_response(legacy_conn, 202)

    assert source_id == legacy_source.id
    legacy_agent = Inventory.get_agent!(scope, agent_id)
    assert legacy_agent.last_auth_method == "legacy_source_token"
    assert legacy_agent.last_legacy_authenticated_at

    intake_conn =
      build_conn()
      |> authorize(intake_token, @first_installation_id)
      |> post(~p"/api/v1/observations", valid_observation_payload())

    assert %{"observation" => %{"id" => observation_id, "source_id" => ^source_id}} =
             json_response(intake_conn, 202)

    migrated_agent = Inventory.get_agent!(scope, agent_id)
    assert migrated_agent.source_id == legacy_source.id
    assert migrated_agent.last_auth_method == "intake_api_key"

    assert migrated_agent.last_legacy_authenticated_at ==
             legacy_agent.last_legacy_authenticated_at

    assert Repo.get!(Renga.Inventory.Observation, observation_id).source_id == legacy_source.id
    assert length(Inventory.list_sources(scope)) == 1
    assert length(Inventory.list_agents(scope)) == 1
  end

  defp authorize(conn, token, installation_id) do
    conn
    |> put_req_header("authorization", "Bearer #{token}")
    |> put_req_header("x-renga-installation-id", installation_id)
  end

  defp post_check_in(conn) do
    post(conn, ~p"/api/v1/agent/checkins", %{
      "source" => %{"kind" => "host_agent"},
      "capabilities" => ["host.inventory"],
      "metadata" => %{"agent_version" => "0.1.0"}
    })
  end

  defp valid_observation_payload do
    %{
      "observation_id" => "intake-#{System.unique_integer([:positive])}",
      "observed_at" => "2026-08-13T07:30:00Z",
      "source" => %{"kind" => "host_agent"},
      "resources" => [
        %{
          "kind" => "server",
          "identifiers" => %{"machine_id" => "intake-machine-id"},
          "attributes" => %{"hostname" => "intake-host"},
          "interfaces" => [],
          "components" => []
        }
      ]
    }
  end
end
