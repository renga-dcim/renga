defmodule RengaWeb.Api.AgentControllerTest do
  use RengaWeb.ConnCase, async: true

  alias Renga.Accounts
  alias Renga.Inventory

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
        name: Map.get(attrs, :name, "compute-01-agent"),
        capabilities: Map.get(attrs, :capabilities, [])
      })

    %{organization: organization, scope: scope, source: source, token: token}
  end

  defp authorize(conn, token) do
    put_req_header(conn, "authorization", "Bearer #{token}")
  end

  describe "POST /api/agent/checkins" do
    test "requires a valid source bearer token", %{conn: conn} do
      conn = post(conn, ~p"/api/agent/checkins", %{})

      assert %{"errors" => [%{"path" => "authorization"}]} = json_response(conn, 401)
    end

    test "records host-agent check-ins using authenticated source scope", %{conn: conn} do
      %{scope: scope, source: source, token: token} = source_fixture()

      conn =
        conn
        |> authorize(token)
        |> post(~p"/api/agent/checkins", %{
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
               }
             } = json_response(conn, 202)

      assert source_id == source.id
      assert {:ok, _timestamp, 0} = DateTime.from_iso8601(last_seen_at)

      checked_in_source = Inventory.get_source!(scope, source.id)
      assert checked_in_source.last_seen_at
      assert checked_in_source.capabilities == ["host.inventory"]
      assert checked_in_source.metadata == %{"agent_version" => "0.1.0"}
    end

    test "rejects payloads that claim a different source", %{conn: conn} do
      %{source: source, token: token} = source_fixture()

      conn =
        conn
        |> authorize(token)
        |> post(~p"/api/agent/checkins", %{
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
        |> post(~p"/api/agent/checkins", %{})

      assert %{"errors" => [%{"path" => "source.kind", "message" => "must be host_agent"}]} =
               json_response(conn, 403)
    end
  end
end
