defmodule RengaWeb.Api.V1.AgentControllerTest do
  use RengaWeb.ConnCase, async: true

  alias Renga.Accounts
  alias Renga.Inventory
  alias Renga.Inventory.AgentPayload

  @installation_id "67e55044-10b1-426f-9247-bb680e5fe0c8"
  @other_installation_id "8ea9ae04-bf9b-4c34-8192-4f617eade95e"

  defp unique_slug(prefix), do: "#{prefix}-#{System.unique_integer([:positive])}"

  defp source_fixture(attrs \\ %{}) do
    {:ok, organization} =
      Accounts.create_organization(%{
        name: Map.get(attrs, :organization_name, "Acme Operations"),
        slug: unique_slug(Map.get(attrs, :organization_slug_prefix, "acme-ops"))
      })

    scope = Accounts.scope_for(organization)

    {:ok, {source, token}} =
      Inventory.create_source_with_token(scope, %{
        kind: Map.get(attrs, :kind, "host_agent"),
        name: Map.get(attrs, :name, "compute-01-agent")
      })

    %{organization: organization, scope: scope, source: source, token: token}
  end

  defp authorize(conn, token, installation_id \\ @installation_id) do
    conn
    |> put_req_header("authorization", "Bearer #{token}")
    |> put_req_header("x-renga-installation-id", installation_id)
  end

  describe "POST /api/v1/agent/checkins" do
    test "requires a valid source bearer token", %{conn: conn} do
      conn = post(conn, ~p"/api/v1/agent/checkins", %{})

      assert %{"errors" => [%{"path" => "authorization"}]} = json_response(conn, 401)
    end

    test "requires a valid installation identity with the source token" do
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

    test "records host-agent check-ins using authenticated source scope", %{conn: conn} do
      %{scope: scope, source: source, token: token} = source_fixture()

      conn =
        conn
        |> authorize(token)
        |> post(~p"/api/v1/agent/checkins", %{
          "source" => %{"kind" => "host_agent", "source_id" => source.name},
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

    test "binds a source token to its first installation identity", %{conn: conn} do
      %{token: token} = source_fixture()

      first_conn =
        conn
        |> authorize(token)
        |> post(~p"/api/v1/agent/checkins", %{})

      assert %{"status" => "accepted"} = json_response(first_conn, 202)

      conflicting_conn =
        build_conn()
        |> authorize(token, @other_installation_id)
        |> post(~p"/api/v1/agent/checkins", %{})

      assert %{
               "status" => "rejected",
               "errors" => [%{"path" => "installation_id", "message" => message}]
             } = json_response(conflicting_conn, 409)

      assert message =~ "already enrolled"
    end

    test "does not allow one installation identity to enroll two source credentials", %{
      conn: conn
    } do
      %{scope: scope, token: first_token} = source_fixture()

      {:ok, {second_source, second_token}} =
        Inventory.create_source_with_token(scope, %{
          kind: "host_agent",
          name: "compute-02-agent"
        })

      first_conn =
        conn
        |> authorize(first_token)
        |> post(~p"/api/v1/agent/checkins", %{})

      assert %{"status" => "accepted"} = json_response(first_conn, 202)

      conflicting_conn =
        build_conn()
        |> authorize(second_token)
        |> post(~p"/api/v1/agent/checkins", %{})

      assert %{"status" => "rejected", "errors" => [%{"path" => "installation_id"}]} =
               json_response(conflicting_conn, 409)

      refute Enum.any?(Inventory.list_agents(scope), &(&1.source_id == second_source.id))
    end

    test "rejects a request authenticated before its credential was rotated" do
      %{scope: scope, token: token} = source_fixture()
      assert {:ok, authenticated_source} = Inventory.authenticate_source_token(token)

      assert {:ok, {_source, _new_token}} =
               Inventory.rotate_source_token(scope, authenticated_source.id)

      assert {:error, :source_credential_changed} =
               Inventory.record_authenticated_agent_check_in(scope, authenticated_source, %{
                 installation_id: @installation_id
               })

      refute Enum.any?(Inventory.list_agents(scope), &(&1.source_id == authenticated_source.id))
    end

    test "an old authenticated request cannot recreate an agent after enrollment reset" do
      %{scope: scope, token: token} = source_fixture()
      assert {:ok, authenticated_source} = Inventory.authenticate_source_token(token)

      assert {:ok, {_agent, _lease}} =
               Inventory.record_authenticated_agent_check_in(scope, authenticated_source, %{
                 installation_id: @installation_id
               })

      admin_scope = %{scope | user: %{}, roles: ["admin"]}

      assert {:ok, {_source, _new_token}} =
               Inventory.reset_collector_enrollment(admin_scope, authenticated_source.id)

      assert {:error, :source_credential_changed} =
               Inventory.record_authenticated_agent_check_in(scope, authenticated_source, %{
                 installation_id: @installation_id
               })

      refute Enum.any?(Inventory.list_agents(scope), &(&1.source_id == authenticated_source.id))
    end

    test "accepts an optional source object without a kind", %{conn: conn} do
      %{source: source, token: token} = source_fixture()

      conn =
        conn
        |> authorize(token)
        |> post(~p"/api/v1/agent/checkins", %{
          "source" => %{"source_id" => source.name},
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

    test "rejects non-host-agent sources", %{conn: conn} do
      %{token: token} = source_fixture(%{kind: "manual", name: "manual-import"})

      conn =
        conn
        |> authorize(token)
        |> post(~p"/api/v1/agent/checkins", %{})

      assert %{"errors" => [%{"path" => "source.kind", "message" => "must be host_agent"}]} =
               json_response(conn, 403)
    end
  end
end
