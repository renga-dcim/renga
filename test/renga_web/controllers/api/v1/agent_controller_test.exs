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

      assert %{"errors" => [%{"path" => "authorization"}]} = valid_api_response(conn, 401)
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

        assert %{"errors" => [%{"path" => "authorization"}]} = valid_api_response(conn, 401)
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
             } = valid_api_response(conn, 202)

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

      assert %{"status" => "accepted"} = valid_api_response(conn, 202)
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
               } = valid_api_response(conn, 422)
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
             } = valid_api_response(conn, 422)
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

      %{"agent" => %{"id" => agent_id}} = valid_api_response(conn, 202)
      agent = Inventory.get_agent!(scope, agent_id)

      assert %{entries: 3, bytes: 12_000, oldest_age_seconds: 5_400, dropped: 3} =
               Renga.Inventory.Agent.observation_queue(agent)

      # An empty queue has no oldest entry, and each check-in replaces the last report.
      empty = %{queue | "entries" => 0, "bytes" => 0, "oldest_age_seconds" => nil}
      conn = check_in_json(build_conn(), token, %{"observation_queue" => empty})
      assert valid_api_response(conn, 202)

      assert %{entries: 0, oldest_age_seconds: nil} =
               scope
               |> Inventory.get_agent!(agent_id)
               |> Renga.Inventory.Agent.observation_queue()

      max = 9_007_199_254_740_991
      boundary = %{queue | "entries" => max, "bytes" => max, "oldest_age_seconds" => max}
      conn = check_in_json(build_conn(), token, %{"observation_queue" => boundary})
      assert valid_api_response(conn, 202)

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
                 valid_api_response(conn, 422)
      end
    end

    test "stores the telemetry queue beside the observation queue", %{conn: conn} do
      %{scope: scope, token: token} = source_fixture()

      queue = %{
        "entries" => 2,
        "bytes" => 900,
        "oldest_age_seconds" => 120,
        "dropped_for_space" => 0,
        "expired" => 0,
        "rejected" => 0,
        "unreadable" => 0
      }

      telemetry = %{
        queue
        | "expired" => 5
      }

      telemetry =
        Map.merge(telemetry, %{
          "dropped_earliest_age_seconds" => 90_000,
          "dropped_latest_age_seconds" => 86_500
        })

      conn =
        check_in_json(conn, token, %{
          "observation_queue" => queue,
          "telemetry_queue" => telemetry
        })

      %{"agent" => %{"id" => agent_id}} = valid_api_response(conn, 202)
      agent = Inventory.get_agent!(scope, agent_id)

      assert %{entries: 2, dropped: 0, dropped_ages: nil} =
               Renga.Inventory.Agent.observation_queue(agent)

      assert %{entries: 2, expired: 5, dropped: 5, dropped_ages: {90_000, 86_500}} =
               Renga.Inventory.Agent.telemetry_queue(agent)

      for {key, value, path} <- [
            {"expired", -1, "metadata.telemetry_queue.expired"},
            {"dropped_latest_age_seconds", "1",
             "metadata.telemetry_queue.dropped_latest_age_seconds"}
          ] do
        conn =
          check_in_json(build_conn(), token, %{"telemetry_queue" => %{telemetry | key => value}})

        assert %{"errors" => [%{"path" => ^path, "message" => "must be a non-negative integer"}]} =
                 valid_api_response(conn, 422)
      end
    end

    test "stores which power sources the agent can read", %{conn: conn} do
      %{scope: scope, token: token} = source_fixture()

      sources = [
        %{"source" => "hwmon", "status" => "not_present"},
        %{"source" => "http://127.0.0.1:9290/metrics", "status" => "unreachable"}
      ]

      conn = check_in_json(conn, token, %{"power_sources" => sources})
      %{"agent" => %{"id" => agent_id}} = valid_api_response(conn, 202)

      assert Renga.Inventory.Agent.power_sources(Inventory.get_agent!(scope, agent_id)) == [
               %{source: "hwmon", status: "not_present"},
               %{source: "http://127.0.0.1:9290/metrics", status: "unreachable"}
             ]

      for {sources, path, message} <- [
            {%{}, "metadata.power_sources", "must be an array"},
            {List.duplicate(hd(sources), 33), "metadata.power_sources",
             "must have at most 32 entries"},
            {[%{"source" => "hwmon"}], "metadata.power_sources.0",
             "must be an object with a source and a status"},
            {[%{"source" => " ", "status" => "available"}], "metadata.power_sources.0.source",
             "must be a non-blank string of at most 255 characters"},
            {[%{"source" => "hwmon", "status" => "broken"}], "metadata.power_sources.0.status",
             "must be one of available, not_permitted, not_present, unreachable"}
          ] do
        conn = check_in_json(build_conn(), token, %{"power_sources" => sources})

        assert %{"errors" => [%{"path" => ^path, "message" => ^message}]} =
                 valid_api_response(conn, 422)
      end
    end

    test "records the osquery backend's status (RFD 12)", %{conn: conn} do
      %{scope: scope, token: token} = source_fixture()

      osquery = %{"status" => "available", "version" => "5.12.1"}
      conn = check_in_json(conn, token, %{"query_backends" => %{"osquery" => osquery}})
      %{"agent" => %{"id" => agent_id}} = valid_api_response(conn, 202)

      assert %{status: "available", version: "5.12.1"} =
               scope |> Inventory.get_agent!(agent_id) |> Renga.Inventory.Agent.osquery()

      # Backends this server does not know are ignored.
      backends = %{"osquery" => %{"status" => "not_permitted"}, "dtrace" => %{"status" => "?"}}
      conn = check_in_json(build_conn(), token, %{"query_backends" => backends})
      assert valid_api_response(conn, 202)

      assert %{status: "not_permitted", version: nil} =
               scope |> Inventory.get_agent!(agent_id) |> Renga.Inventory.Agent.osquery()
    end

    test "rejects malformed query backends", %{conn: conn} do
      %{token: token} = source_fixture()

      for {backends, path, message} <- [
            {[], "metadata.query_backends", "must be an object"},
            {%{"osquery" => "available"}, "metadata.query_backends.osquery", "must be an object"},
            {%{"osquery" => %{"status" => "running"}}, "metadata.query_backends.osquery.status",
             "must be one of available, not_permitted, not_present"},
            {%{"osquery" => %{"status" => "available", "version" => String.duplicate("9", 65)}},
             "metadata.query_backends.osquery.version", "must be a string of at most 64 bytes"}
          ] do
        conn = check_in_json(conn, token, %{"query_backends" => backends})

        assert %{"errors" => [%{"path" => ^path, "message" => ^message}]} =
                 valid_api_response(conn, 422)
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
             } = valid_api_response(conn, 422)
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
             } = valid_api_response(conn, 422)
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
             } = valid_api_response(conn, 422)
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
             } = valid_api_response(conn, 422)
    end
  end

  describe "installation keys" do
    defp check_in_key(conn, token, installation_key) do
      conn
      |> authorize(token)
      |> put_req_header("content-type", "application/json")
      |> post(
        ~p"/api/v1/agent/checkins",
        Jason.encode!(%{"installation_key" => installation_key})
      )
    end

    defp encoded(raw), do: Base.url_encode64(raw, padding: false)

    test "records a presented key as pending and reports its fingerprint", %{conn: conn} do
      %{token: token, scope: scope, source: source} = source_fixture()
      raw = :crypto.strong_rand_bytes(32)
      fingerprint = Renga.Inventory.InstallationKey.fingerprint(raw)

      response =
        conn
        |> check_in_key(token, %{"algorithm" => "ed25519", "public_key" => encoded(raw)})
        |> valid_api_response(202)

      assert response["installation_key"] == %{
               "fingerprint" => fingerprint,
               "status" => "pending"
             }

      agent = scope |> Inventory.list_agents() |> Enum.find(&(&1.source_id == source.id))
      assert Renga.Inventory.InstallationKeys.current(scope, agent.id).fingerprint == fingerprint
    end

    test "omits the key from the response when none was presented", %{conn: conn} do
      %{token: token} = source_fixture()
      response = conn |> check_in_json(token, %{}) |> valid_api_response(202)
      refute Map.has_key?(response, "installation_key")
    end

    test "rejects keys that are not 32-byte Ed25519 keys", %{conn: _conn} do
      %{token: token} = source_fixture()

      for {key, path} <- [
            {%{"algorithm" => "ed25519", "public_key" => encoded(<<1, 2, 3>>)},
             "installation_key.public_key"},
            {%{"algorithm" => "rsa", "public_key" => encoded(:crypto.strong_rand_bytes(32))},
             "installation_key.algorithm"}
          ] do
        response = build_conn() |> check_in_key(token, key) |> valid_api_response(422)
        assert [%{"path" => ^path} | _rest] = response["errors"]
      end
    end
  end
end
