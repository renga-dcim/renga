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

    test "rejects malformed canonical projection fields before raw storage", %{conn: conn} do
      %{source: source, token: token} = source_fixture()

      payload =
        source
        |> valid_observation_payload()
        |> put_in(["resources", Access.at(0), "attributes", "vendor"], %{})
        |> put_in(["resources", Access.at(0), "interfaces", Access.at(0), "mtu"], -1)
        |> put_in(
          ["resources", Access.at(0), "interfaces", Access.at(0), "metadata"],
          "invalid"
        )

      conn =
        conn
        |> authorize(token)
        |> post(~p"/api/v1/observations", payload)

      assert %{"status" => "rejected", "errors" => errors} = json_response(conn, 422)
      paths = Enum.map(errors, & &1["path"])
      assert "resources.0.attributes.vendor" in paths
      assert "resources.0.interfaces.0.mtu" in paths
      assert "resources.0.interfaces.0.metadata" in paths
      assert Repo.aggregate(Observation, :count) == 0
    end

    test "rejects explicit null interface kind and status before raw storage" do
      %{source: source, token: token} = source_fixture()

      for field <- ~w(kind status) do
        payload =
          source
          |> valid_observation_payload(%{"observation_id" => "null-interface-#{field}"})
          |> put_in(["resources", Access.at(0), "interfaces", Access.at(0), field], nil)

        response =
          build_conn()
          |> authorize(token)
          |> post(~p"/api/v1/observations", payload)
          |> json_response(422)

        assert %{"status" => "rejected", "errors" => errors} = response
        assert Enum.any?(errors, &(&1["path"] == "resources.0.interfaces.0.#{field}"))
      end

      assert Repo.aggregate(Observation, :count) == 0
    end

    test "rejects explicit null address kind before raw storage", %{conn: conn} do
      %{source: source, token: token} = source_fixture()

      payload =
        source
        |> valid_observation_payload(%{"observation_id" => "null-address-kind"})
        |> put_in(
          [
            "resources",
            Access.at(0),
            "interfaces",
            Access.at(0),
            "addresses",
            Access.at(0),
            "kind"
          ],
          nil
        )

      response =
        conn
        |> authorize(token)
        |> post(~p"/api/v1/observations", payload)
        |> json_response(422)

      assert %{"status" => "rejected", "errors" => errors} = response
      assert Enum.any?(errors, &(&1["path"] == "resources.0.interfaces.0.addresses.0.kind"))
      assert Repo.aggregate(Observation, :count) == 0
    end

    test "rejects identifiers that exceed their projection storage limit before raw storage" do
      %{source: source, token: token} = source_fixture()
      oversized = String.duplicate("i", 256)

      payloads = [
        put_in(valid_observation_payload(source), ["resources", Access.at(0), "identifiers"], %{
          "machine_id" => oversized
        }),
        put_in(valid_observation_payload(source), ["resources", Access.at(0), "identifiers"], %{
          "serial_number" => ["valid", oversized]
        })
      ]

      for payload <- payloads do
        response =
          build_conn()
          |> authorize(token)
          |> post(~p"/api/v1/observations", payload)
          |> json_response(422)

        assert %{"status" => "rejected", "errors" => errors} = response
        assert Enum.any?(errors, &String.starts_with?(&1["path"], "resources.0.identifiers."))
      end

      assert Repo.aggregate(Observation, :count) == 0
    end

    test "rejects multi-valued hostname and FQDN identifiers before raw storage" do
      %{source: source, token: token} = source_fixture()

      for field <- ~w(hostname fqdn) do
        payload =
          put_in(valid_observation_payload(source), ["resources", Access.at(0), "identifiers"], %{
            field => ["compute-01", "compute-02"],
            "machine_id" => "9f3c7a8b"
          })

        response =
          build_conn()
          |> authorize(token)
          |> post(~p"/api/v1/observations", payload)
          |> json_response(422)

        assert %{"status" => "rejected", "errors" => errors} = response
        assert Enum.any?(errors, &(&1["path"] == "resources.0.identifiers.#{field}"))
      end

      assert Repo.aggregate(Observation, :count) == 0
    end

    test "rejects malformed MAC identifiers before raw storage", %{conn: conn} do
      %{source: source, token: token} = source_fixture()

      payload =
        put_in(valid_observation_payload(source), ["resources", Access.at(0), "identifiers"], %{
          "machine_id" => "9f3c7a8b",
          "mac_address" => ["aa:bb:cc:dd:ee:ff", "not-a-mac"]
        })

      response =
        conn
        |> authorize(token)
        |> post(~p"/api/v1/observations", payload)
        |> json_response(422)

      assert %{"status" => "rejected", "errors" => errors} = response
      assert Enum.any?(errors, &(&1["path"] == "resources.0.identifiers.mac_address"))
      assert Repo.aggregate(Observation, :count) == 0
    end

    test "rejects top-level MAC identity that is not the current interface MAC set" do
      %{source: source, token: token} = source_fixture()

      resources = [
        %{
          "kind" => "server",
          "identifiers" => %{
            "hostname" => "compute-01",
            "mac_address" => "aa:bb:cc:dd:ee:ff"
          }
        },
        %{
          "kind" => "server",
          "identifiers" => %{
            "hostname" => "compute-02",
            "mac_address" => "aa:bb:cc:dd:ee:ff"
          },
          "interfaces" => [
            %{
              "name" => "eth0",
              "status" => "not_present",
              "mac_address" => "aa:bb:cc:dd:ee:ff"
            }
          ]
        }
      ]

      for resource <- resources do
        response =
          build_conn()
          |> authorize(token)
          |> post(
            ~p"/api/v1/observations",
            valid_observation_payload(source, %{"resources" => [resource]})
          )
          |> json_response(422)

        assert %{"status" => "rejected", "errors" => errors} = response
        assert Enum.any?(errors, &(&1["path"] == "resources.0.identifiers.mac_address"))
      end

      assert Repo.aggregate(Observation, :count) == 0
    end

    test "accepts a top-level MAC identity equal to the current interface MAC set", %{conn: conn} do
      %{source: source, token: token} = source_fixture()

      payload =
        put_in(valid_observation_payload(source), ["resources", Access.at(0), "identifiers"], %{
          "hostname" => "compute-01",
          "mac_address" => "aa-bb-cc-dd-ee-ff"
        })

      conn = conn |> authorize(token) |> post(~p"/api/v1/observations", payload)
      assert %{"status" => "accepted"} = json_response(conn, 202)
    end

    test "rejects identity containing only matcher-unsupported identifiers before raw storage" do
      %{source: source, token: token} = source_fixture()

      for identifiers <- [
            %{"provider_instance_id" => "i-123"},
            %{"bmc_address" => "192.0.2.20"}
          ] do
        payload =
          put_in(
            valid_observation_payload(source),
            ["resources", Access.at(0), "identifiers"],
            identifiers
          )

        response =
          build_conn()
          |> authorize(token)
          |> post(~p"/api/v1/observations", payload)
          |> json_response(422)

        assert %{"status" => "rejected", "errors" => errors} = response
        assert Enum.any?(errors, &(&1["path"] == "resources.0.identifiers"))
      end

      assert Repo.aggregate(Observation, :count) == 0
    end

    test "rejects interface integers above PostgreSQL's signed limit before raw storage", %{
      conn: conn
    } do
      %{source: source, token: token} = source_fixture()

      payload =
        source
        |> valid_observation_payload()
        |> put_in(
          ["resources", Access.at(0), "interfaces", Access.at(0), "mtu"],
          2_147_483_648
        )
        |> put_in(
          ["resources", Access.at(0), "interfaces", Access.at(0), "speed_mbps"],
          2_147_483_648
        )

      response =
        conn
        |> authorize(token)
        |> post(~p"/api/v1/observations", payload)
        |> json_response(422)

      assert %{"status" => "rejected", "errors" => errors} = response
      paths = Enum.map(errors, & &1["path"])
      assert "resources.0.interfaces.0.mtu" in paths
      assert "resources.0.interfaces.0.speed_mbps" in paths
      assert Repo.aggregate(Observation, :count) == 0
    end

    test "rejects MAC-only identity before raw storage", %{conn: conn} do
      %{scope: scope, source: source, token: token} = source_fixture()

      payload =
        source
        |> valid_observation_payload()
        |> put_in(["resources", Access.at(0), "identifiers"], %{
          "mac_address" => "aa:bb:cc:dd:ee:ff"
        })

      conn = conn |> authorize(token) |> post(~p"/api/v1/observations", payload)

      assert %{"status" => "rejected", "errors" => errors} = json_response(conn, 422)
      assert Enum.any?(errors, &(&1["path"] == "resources.0.identifiers"))

      repeated_conn =
        build_conn()
        |> authorize(token)
        |> post(~p"/api/v1/observations", Map.put(payload, "observation_id", "repeated-mac"))

      assert %{"status" => "rejected"} = json_response(repeated_conn, 422)
      assert Repo.aggregate(Observation, :count) == 0
      assert Inventory.list_resources(scope) == []
    end

    test "rejects hostname and FQDN disagreement between identifiers and attributes", %{
      conn: conn
    } do
      %{source: source, token: token} = source_fixture()

      resource = %{
        "kind" => "server",
        "identifiers" => %{
          "hostname" => "identifier-host",
          "fqdn" => "identifier.example.com"
        },
        "attributes" => %{
          "hostname" => "attribute-host",
          "fqdn" => "attribute.example.com"
        }
      }

      payload = valid_observation_payload(source, %{"resources" => [resource]})
      conn = conn |> authorize(token) |> post(~p"/api/v1/observations", payload)

      assert %{"status" => "rejected", "errors" => errors} = json_response(conn, 422)
      paths = Enum.map(errors, & &1["path"])
      assert "resources.0.attributes.hostname" in paths
      assert "resources.0.attributes.fqdn" in paths
      assert Repo.aggregate(Observation, :count) == 0
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

    test "a duplicate request recovers a stored observation with no reconciliation attempt", %{
      conn: conn
    } do
      %{scope: scope, source: source, token: token} = source_fixture()
      payload = valid_observation_payload(source, %{"observation_id" => "stored-before-crash"})
      {:ok, observed_at, _offset} = DateTime.from_iso8601(payload["observed_at"])

      {:ok, observation} =
        Inventory.create_observation(scope, source.id, %{
          idempotency_key: payload["observation_id"],
          observed_at: observed_at,
          payload: payload
        })

      conn =
        conn
        |> authorize(token)
        |> post(~p"/api/v1/observations", payload)

      assert %{
               "duplicate" => true,
               "reconciliation" => %{
                 "status" => "succeeded",
                 "matched_resource_id" => resource_id
               }
             } = json_response(conn, 200)

      assert resource_id

      assert [%{status: "succeeded"}] =
               Inventory.list_observation_reconciliations(scope, observation.id)
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
        payload
        |> put_in(["resources", Access.at(0), "identifiers", "hostname"], "compute-02")
        |> put_in(["resources", Access.at(0), "attributes", "hostname"], "compute-02")

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
