defmodule RengaWeb.Api.V1.AgentControllerTest do
  use RengaWeb.ConnCase, async: true

  import Renga.AccountsFixtures
  import Renga.InventoryFixtures

  alias Renga.Accounts
  alias Renga.Inventory
  alias Renga.Inventory.AgentPayload

  @installation_id "67e55044-10b1-426f-9247-bb680e5fe0c8"
  defp unique_slug(prefix), do: "#{prefix}-#{System.unique_integer([:positive])}"

  defp source_fixture(attrs \\ %{}) do
    {:ok, organization} =
      Accounts.create_organization(%{
        name: Map.get(attrs, :organization_name, "Acme Operations"),
        slug: unique_slug(Map.get(attrs, :organization_slug_prefix, "acme-ops"))
      })

    scope = Accounts.scope_for(organization)
    admin = user_fixture()
    organization_membership_fixture(admin, organization, %{role: "admin"})
    admin_scope = Accounts.scope_for_user(admin, organization.id)

    {:ok, {_key, token}} =
      Inventory.create_intake_api_key(admin_scope, %{name: Map.get(attrs, :name, "Test fleet")})

    {:ok, authenticated_key} = Inventory.authenticate_intake_api_key(token)

    {:ok, {agent, _lease}} =
      Inventory.record_intake_agent_check_in(scope, authenticated_key, @installation_id)

    source = Inventory.get_source!(scope, agent.source_id)

    %{
      organization: organization,
      scope: scope,
      admin_scope: admin_scope,
      source: source,
      token: token
    }
  end

  # Posts a JSON body so integers and nulls arrive as JSON types, as from the agent.
  defp check_in_json(conn, token, metadata) do
    conn
    |> authorize(token)
    |> put_req_header("content-type", "application/json")
    |> post(~p"/api/v1/agent/checkins", Jason.encode!(%{"metadata" => metadata}))
  end

  defp authorize(conn, token, installation_id \\ @installation_id) do
    conn
    |> put_req_header("authorization", "Bearer #{token}")
    |> put_req_header("x-renga-installation-id", installation_id)
  end

  describe "POST /api/v1/agent/checkins" do
    test "requires a valid organization intake key", %{conn: conn} do
      conn = post(conn, ~p"/api/v1/agent/checkins", %{})

      assert %{"errors" => [%{"path" => "authorization"}]} = json_response(conn, 401)
    end

    test "requires a valid installation identity with the intake key" do
      %{token: token} = source_fixture()

      for installation_id <- [nil, "not-a-uuid"] do
        conn = put_req_header(build_conn(), "authorization", "Bearer #{token}")

        conn =
          if installation_id,
            do: put_req_header(conn, "x-renga-installation-id", installation_id),
            else: conn

        conn = post(conn, ~p"/api/v1/agent/checkins", %{})

        assert %{"errors" => [%{"path" => "authorization"}]} = json_response(conn, 401)
      end
    end

    test "records host-agent check-ins using the authenticated organization scope", %{conn: conn} do
      %{scope: scope, source: source, token: token} = source_fixture()

      conn =
        conn
        |> authorize(token)
        |> post(~p"/api/v1/agent/checkins", %{
          "source" => %{"kind" => "host_agent"},
          "capabilities" => ["host.inventory"],
          "metadata" => %{"agent_version" => "0.1.0"}
        })

      assert %{
               "status" => "accepted",
               "source" => %{
                 "id" => source_id,
                 "kind" => "host_agent",
                 "last_seen_at" => last_seen_at
               },
               "agent" => %{
                 "id" => agent_id,
                 "lease_expires_at" => lease_expires_at
               }
             } = json_response(conn, 202)

      assert source_id == source.id
      assert {:ok, _timestamp, 0} = DateTime.from_iso8601(last_seen_at)
      assert {:ok, _timestamp, 0} = DateTime.from_iso8601(lease_expires_at)

      agent = Inventory.get_agent!(scope, agent_id)
      assert agent.source_id == source.id
      assert agent.installation_id == @installation_id
      assert agent.capabilities == ["host.inventory"]
      assert agent.version == "0.1.0"
      assert agent.metadata == %{"agent_version" => "0.1.0"}
      assert Inventory.get_agent_lease!(scope, agent.id).expires_at
    end

    test "accepts an optional source object without a kind", %{conn: conn} do
      %{token: token} = source_fixture()

      conn =
        conn
        |> authorize(token)
        |> post(~p"/api/v1/agent/checkins", %{
          "source" => %{},
          "capabilities" => ["host.inventory"]
        })

      assert %{"status" => "accepted"} = json_response(conn, 202)
    end

    test "rejects non-string agent versions without crashing", %{conn: conn} do
      %{token: token} = source_fixture()

      for invalid_version <- [%{"major" => 1}, ["0.1.0"]] do
        conn =
          conn
          |> authorize(token)
          |> post(~p"/api/v1/agent/checkins", %{
            "metadata" => %{"agent_version" => invalid_version}
          })

        assert %{
                 "status" => "rejected",
                 "errors" => [
                   %{"path" => "metadata.agent_version", "message" => "must be a string"}
                 ]
               } = json_response(conn, 422)
      end
    end

    test "rejects agent versions longer than the storage limit", %{conn: conn} do
      %{token: token} = source_fixture()

      conn =
        conn
        |> authorize(token)
        |> post(~p"/api/v1/agent/checkins", %{
          "metadata" => %{"agent_version" => String.duplicate("v", 256)}
        })

      assert %{
               "status" => "rejected",
               "errors" => [
                 %{
                   "path" => "metadata.agent_version",
                   "message" => "must be at most 255 characters"
                 }
               ]
             } = json_response(conn, 422)
    end

    test "stores the observation queue health the agent reports", %{conn: conn} do
      %{scope: scope, token: token} = source_fixture()

      queue = %{
        "entries" => 3,
        "bytes" => 12_000,
        "oldest_age_seconds" => 5_400,
        "dropped_for_space" => 1,
        "expired" => 0,
        "rejected" => 2,
        "unreadable" => 0,
        "added_by_a_newer_agent" => true
      }

      conn =
        check_in_json(conn, token, %{"agent_version" => "0.2.0", "observation_queue" => queue})

      %{"agent" => %{"id" => agent_id}} = json_response(conn, 202)
      agent = Inventory.get_agent!(scope, agent_id)

      assert %{entries: 3, bytes: 12_000, oldest_age_seconds: 5_400, dropped: 3} =
               Renga.Inventory.Agent.observation_queue(agent)

      # An empty queue has no oldest entry, and each check-in replaces the last report.
      empty = %{queue | "entries" => 0, "bytes" => 0, "oldest_age_seconds" => nil}
      conn = check_in_json(build_conn(), token, %{"observation_queue" => empty})
      assert json_response(conn, 202)

      assert %{entries: 0, oldest_age_seconds: nil} =
               scope
               |> Inventory.get_agent!(agent_id)
               |> Renga.Inventory.Agent.observation_queue()

      max = 9_007_199_254_740_991
      boundary = %{queue | "entries" => max, "bytes" => max, "oldest_age_seconds" => max}
      conn = check_in_json(build_conn(), token, %{"observation_queue" => boundary})
      assert json_response(conn, 202)

      assert %{entries: ^max, bytes: ^max, oldest_age_seconds: ^max} =
               scope
               |> Inventory.get_agent!(agent_id)
               |> Renga.Inventory.Agent.observation_queue()
    end

    test "rejects malformed observation queue health", %{conn: conn} do
      %{token: token} = source_fixture()

      valid = %{
        "entries" => 0,
        "bytes" => 0,
        "oldest_age_seconds" => nil,
        "dropped_for_space" => 0,
        "expired" => 0,
        "rejected" => 0,
        "unreadable" => 0
      }

      for {queue, path, message} <- [
            {[], "metadata.observation_queue", "must be an object"},
            {%{valid | "entries" => -1}, "metadata.observation_queue.entries",
             "must be a non-negative integer"},
            {%{valid | "bytes" => "12"}, "metadata.observation_queue.bytes",
             "must be a non-negative integer"},
            {%{valid | "bytes" => 9_007_199_254_740_992}, "metadata.observation_queue.bytes",
             "must be a non-negative integer"},
            {Map.delete(valid, "expired"), "metadata.observation_queue.expired",
             "must be a non-negative integer"},
            {%{valid | "oldest_age_seconds" => 1.5},
             "metadata.observation_queue.oldest_age_seconds",
             "must be a non-negative integer or null"},
            {%{valid | "oldest_age_seconds" => 9_007_199_254_740_992},
             "metadata.observation_queue.oldest_age_seconds",
             "must be a non-negative integer or null"},
            {Map.delete(valid, "oldest_age_seconds"),
             "metadata.observation_queue.oldest_age_seconds", "is required"}
          ] do
        conn = check_in_json(conn, token, %{"observation_queue" => queue})

        assert %{"errors" => [%{"path" => ^path, "message" => ^message}]} =
                 json_response(conn, 422)
      end
    end

    test "rejects metadata larger than the encoded storage limit", %{conn: conn} do
      %{token: token} = source_fixture()

      assert AgentPayload.max_agent_metadata_bytes() == 16_000

      conn =
        conn
        |> authorize(token)
        |> post(~p"/api/v1/agent/checkins", %{
          "metadata" => %{"inventory" => String.duplicate("x", 16_000)}
        })

      assert %{
               "status" => "rejected",
               "errors" => [
                 %{"path" => "metadata", "message" => "must encode to at most 16000 bytes"}
               ]
             } = json_response(conn, 422)
    end

    test "rejects capabilities longer than the storage limit", %{conn: conn} do
      %{token: token} = source_fixture()

      conn =
        conn
        |> authorize(token)
        |> post(~p"/api/v1/agent/checkins", %{
          "capabilities" => [String.duplicate("c", 256)]
        })

      assert %{
               "status" => "rejected",
               "errors" => [
                 %{"path" => "capabilities", "message" => "must be at most 255 characters"}
               ]
             } = json_response(conn, 422)
    end

    test "returns validation errors when agent registration fails", %{conn: conn} do
      %{source: source, token: token} = source_fixture()

      assert {:ok, _source} =
               source
               |> Ecto.Changeset.change(name: "   ")
               |> Renga.Repo.update()

      conn =
        conn
        |> authorize(token)
        |> post(~p"/api/v1/agent/checkins", %{})

      assert %{
               "status" => "rejected",
               "errors" => [%{"path" => "agent.name", "message" => "can't be blank"}]
             } = json_response(conn, 422)
    end

    test "rejects payloads that claim a different source", %{conn: conn} do
      %{source: source, token: token} = source_fixture()

      conn =
        conn
        |> authorize(token)
        |> post(~p"/api/v1/agent/checkins", %{
          "source" => %{"kind" => source.kind, "source_id" => "other-agent"}
        })

      assert %{
               "status" => "rejected",
               "errors" => [%{"path" => "source.source_id"}]
             } = json_response(conn, 422)
    end
  end
end
