defmodule RengaWeb.Api.V1.ObservationControllerTest do
  use RengaWeb.ConnCase, async: true

  import Ecto.Query, only: [from: 2]

  alias Renga.Accounts
  alias Renga.Inventory
  alias Renga.Inventory.Agent
  alias Renga.Inventory.Observation
  alias Renga.Inventory.Source
  alias Renga.Repo

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

  defp authorize(conn, token) do
    put_req_header(conn, "authorization", "Bearer #{token}")
  end

  defp valid_observation_payload(source, attrs \\ %{}) do
    Map.merge(
      %{
        "observation_id" => "obs-#{System.unique_integer([:positive])}",
        "observed_at" => "2026-07-31T12:00:00Z",
        "source" => %{"kind" => "host_agent", "source_id" => source.name},
        "resources" => [
          %{
            "kind" => "server",
            "identifiers" => %{
              "hostname" => "compute-01",
              "machine_id" => "9f3c7a8b"
            },
            "attributes" => %{
              "hostname" => "compute-01",
              "vendor" => "Dell Inc.",
              "model" => "PowerEdge R760"
            },
            "interfaces" => [
              %{
                "name" => "eth0",
                "kind" => "ethernet",
                "status" => "up",
                "mac_address" => "aa:bb:cc:dd:ee:ff",
                "addresses" => [
                  %{"kind" => "ipv4", "address" => "192.0.2.10/24"}
                ]
              }
            ],
            "components" => []
          }
        ]
      },
      attrs
    )
  end

  describe "POST /api/v1/observations" do
    test "requires a valid source bearer token", %{conn: conn} do
      conn = post(conn, ~p"/api/v1/observations", %{})

      assert %{"errors" => [%{"path" => "authorization"}]} = json_response(conn, 401)
    end

    test "stores and reconciles accepted raw host observations", %{conn: conn} do
      %{scope: scope, source: source, token: token} = source_fixture()
      payload = valid_observation_payload(source)

      conn =
        conn
        |> authorize(token)
        |> post(~p"/api/v1/observations", payload)

      assert %{
               "status" => "accepted",
               "duplicate" => false,
               "reconciliation" => %{
                 "status" => "succeeded",
                 "matched_resource_id" => resource_id
               },
               "observation" => %{
                 "id" => observation_id,
                 "observation_id" => payload_observation_id,
                 "source_id" => source_id
               }
             } = json_response(conn, 202)

      assert source_id == source.id
      assert payload_observation_id == payload["observation_id"]

      observation = Repo.get!(Observation, observation_id)
      assert observation.organization_id == scope.organization_id
      assert observation.source_id == source.id
      assert observation.payload == payload
      assert observation.idempotency_key == payload["observation_id"]
      assert Repo.get_by!(Agent, organization_id: scope.organization_id, source_id: source.id)

      resource = Inventory.get_resource!(scope, resource_id)
      assert resource.kind == "server"
      assert Inventory.get_host_by_resource!(scope, resource.id).hostname == "compute-01"
      assert [%{name: "eth0"}] = Inventory.list_interfaces(scope, resource.id)
    end

    test "rolls back observation acceptance when agent registration fails", %{conn: conn} do
      %{scope: scope, source: source, token: token} = source_fixture()

      Repo.update_all(from(stored in Source, where: stored.id == ^source.id), set: [name: "   "])
      source = Repo.get!(Source, source.id)
      payload = valid_observation_payload(source)

      conn =
        conn
        |> authorize(token)
        |> post(~p"/api/v1/observations", payload)

      assert %{
               "status" => "rejected",
               "errors" => [%{"path" => "agent.name", "message" => "can't be blank"}]
             } = json_response(conn, 422)

      refute Repo.get_by(Observation,
               organization_id: scope.organization_id,
               source_id: source.id,
               idempotency_key: payload["observation_id"]
             )
    end

    test "accepts an optional source object without a kind", %{conn: conn} do
      %{source: source, token: token} = source_fixture()

      payload =
        source
        |> valid_observation_payload()
        |> put_in(["source"], %{"source_id" => source.name})

      conn =
        conn
        |> authorize(token)
        |> post(~p"/api/v1/observations", payload)

      assert %{"status" => "accepted", "duplicate" => false} = json_response(conn, 202)
    end

    test "rejects a missing observation id", %{conn: conn} do
      %{source: source, token: token} = source_fixture()
      payload = source |> valid_observation_payload() |> Map.delete("observation_id")

      conn =
        conn
        |> authorize(token)
        |> post(~p"/api/v1/observations", payload)

      assert %{
               "status" => "rejected",
               "errors" => [%{"path" => "observation_id", "message" => "is required"}]
             } = json_response(conn, 422)
    end

    test "rejects observation ids longer than the storage limit", %{conn: conn} do
      %{source: source, token: token} = source_fixture()

      payload =
        valid_observation_payload(source, %{"observation_id" => String.duplicate("o", 256)})

      conn =
        conn
        |> authorize(token)
        |> post(~p"/api/v1/observations", payload)

      assert %{
               "status" => "rejected",
               "errors" => [
                 %{
                   "path" => "observation_id",
                   "message" => "must be at most 255 characters"
                 }
               ]
             } = json_response(conn, 422)
    end

    test "returns duplicate acceptance for retried observation ids", %{conn: conn} do
      %{source: source, token: token} = source_fixture()
      payload = valid_observation_payload(source)

      first_conn =
        conn
        |> authorize(token)
        |> post(~p"/api/v1/observations", payload)

      assert %{"observation" => %{"id" => observation_id}} = json_response(first_conn, 202)

      retry_conn =
        build_conn()
        |> authorize(token)
        |> post(~p"/api/v1/observations", payload)

      assert %{
               "status" => "accepted",
               "duplicate" => true,
               "reconciliation" => %{"status" => "succeeded"},
               "observation" => %{"id" => ^observation_id}
             } = json_response(retry_conn, 200)
    end

    test "accepts identical reports when their idempotency keys differ", %{conn: conn} do
      %{source: source, token: token} = source_fixture()
      payload = valid_observation_payload(source, %{"observation_id" => "report-1"})

      conn
      |> authorize(token)
      |> post(~p"/api/v1/observations", payload)
      |> json_response(202)

      second_payload = Map.put(payload, "observation_id", "report-2")

      second_conn =
        build_conn()
        |> authorize(token)
        |> post(~p"/api/v1/observations", second_payload)

      assert %{"status" => "accepted", "duplicate" => false} = json_response(second_conn, 202)
    end

    test "rejects reused observation ids with different payloads", %{conn: conn} do
      %{source: source, token: token} = source_fixture()
      payload = valid_observation_payload(source)

      conn
      |> authorize(token)
      |> post(~p"/api/v1/observations", payload)
      |> json_response(202)

      changed_payload =
        put_in(payload, ["resources", Access.at(0), "attributes", "hostname"], "compute-02")

      conflict_conn =
        build_conn()
        |> authorize(token)
        |> post(~p"/api/v1/observations", changed_payload)

      assert %{
               "status" => "rejected",
               "errors" => [%{"path" => "observation_id"}]
             } = json_response(conflict_conn, 409)
    end

    test "keeps idempotency scoped to the authenticated source tenant", %{conn: conn} do
      %{source: source, token: token} = source_fixture()
      %{source: other_source, token: other_token} = source_fixture(%{name: "other-agent"})

      payload = valid_observation_payload(source, %{"observation_id" => "shared-observation-id"})

      conn
      |> authorize(token)
      |> post(~p"/api/v1/observations", payload)
      |> json_response(202)

      other_payload =
        valid_observation_payload(other_source, %{"observation_id" => "shared-observation-id"})

      other_conn =
        build_conn()
        |> authorize(other_token)
        |> post(~p"/api/v1/observations", other_payload)

      assert %{"status" => "accepted", "duplicate" => false} = json_response(other_conn, 202)
    end

    test "rejects invalid host observation payloads", %{conn: conn} do
      %{source: source, token: token} = source_fixture()

      payload =
        valid_observation_payload(source, %{
          "observed_at" => "not-a-timestamp",
          "resources" => [
            %{
              "kind" => "server",
              "id" => Ecto.UUID.generate(),
              "identifiers" => %{"hostname" => "   "},
              "interfaces" => [
                %{"name" => "eth0", "mac_address" => "not-a-mac"}
              ]
            }
          ]
        })

      conn =
        conn
        |> authorize(token)
        |> post(~p"/api/v1/observations", payload)

      assert %{"status" => "rejected", "errors" => errors} = json_response(conn, 422)

      paths = Enum.map(errors, & &1["path"])
      assert "observed_at" in paths
      assert "resources.0.id" in paths
      assert "resources.0.identifiers.hostname" in paths
      assert "resources.0.interfaces.0.mac_address" in paths
    end

    test "rejects payloads for a different authenticated source", %{conn: conn} do
      %{source: source, token: token} = source_fixture()

      payload =
        valid_observation_payload(source, %{
          "source" => %{"kind" => "host_agent", "source_id" => "other-agent"}
        })

      conn =
        conn
        |> authorize(token)
        |> post(~p"/api/v1/observations", payload)

      assert %{
               "status" => "rejected",
               "errors" => [%{"path" => "source.source_id"}]
             } = json_response(conn, 422)
    end
  end
end
