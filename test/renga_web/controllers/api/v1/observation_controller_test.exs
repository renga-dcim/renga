defmodule RengaWeb.Api.V1.ObservationControllerTest do
  use RengaWeb.ConnCase, async: true

  import Ecto.Query, only: [from: 2]
  import Renga.AccountsFixtures
  import Renga.InventoryFixtures

  alias Renga.Accounts
  alias Renga.Inventory
  alias Renga.Inventory.Agent
  alias Renga.Inventory.AgentPayload
  alias Renga.Inventory.Observation
  alias Renga.Inventory.Source
  alias Renga.Repo
  alias Renga.Topology
  alias Renga.Topology.InterfaceNeighborEvidence

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

  defp authorize(conn, token, installation_id \\ @installation_id) do
    conn
    |> put_req_header("authorization", "Bearer #{token}")
    |> put_req_header("x-renga-installation-id", installation_id)
  end

  defp valid_observation_payload(_source, attrs \\ %{}) do
    Map.merge(
      %{
        "observation_id" => "obs-#{System.unique_integer([:positive])}",
        "observed_at" => "2026-07-31T12:00:00Z",
        "source" => %{"kind" => "host_agent"},
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
    test "requires a valid organization intake key", %{conn: conn} do
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

    test "ingests, replays, partially preserves, and completely withdraws VLAN membership" do
      %{scope: scope, admin_scope: admin_scope, source: source, token: token} = source_fixture()

      {:ok, _source} =
        Inventory.update_source(admin_scope, source, %{
          metadata: %{"interface_vlan_snapshot_policy" => "complete"}
        })

      {:ok, vlan} =
        Topology.create_vlan(
          admin_scope,
          %{lifecycle_state: "active"},
          %{vid: 10, name: "API VLAN", status: "active"}
        )

      {:ok, _mapping} =
        Topology.put_source_vlan_group_mapping(admin_scope, source.id, nil)

      first =
        source
        |> valid_observation_payload(%{
          "observation_id" => "api-vlan-first",
          "section_completeness" => %{"interface_vlans" => true}
        })
        |> put_in(
          ["resources", Access.at(0), "interfaces", Access.at(0), "vlans"],
          [%{"vid" => 10, "tagging_mode" => "tagged"}]
        )

      response =
        build_conn()
        |> authorize(token)
        |> post(~p"/api/v1/observations", first)
        |> json_response(202)

      resource = Inventory.get_resource!(scope, response["reconciliation"]["matched_resource_id"])
      [interface] = Inventory.list_interfaces(scope, resource.id)

      assert [%{vlan_id: vlan_id}] =
               Topology.list_current_interface_vlan_memberships(scope, interface.id)

      assert vlan_id == vlan.id

      replay =
        build_conn()
        |> authorize(token)
        |> post(~p"/api/v1/observations", first)
        |> json_response(200)

      assert replay["duplicate"] == true
      assert length(Topology.list_interface_vlan_evidence(scope, interface.id)) == 1

      partial =
        source
        |> valid_observation_payload(%{
          "observation_id" => "api-vlan-partial",
          "observed_at" => "2026-07-31T12:01:00Z"
        })
        |> put_in(["resources", Access.at(0), "interfaces", Access.at(0), "vlans"], [])

      assert %{"status" => "accepted"} =
               build_conn()
               |> authorize(token)
               |> post(~p"/api/v1/observations", partial)
               |> json_response(202)

      assert [_membership] =
               Topology.list_current_interface_vlan_memberships(scope, interface.id)

      complete =
        source
        |> valid_observation_payload(%{
          "observation_id" => "api-vlan-complete",
          "observed_at" => "2026-07-31T12:02:00Z",
          "section_completeness" => %{"interface_vlans" => true}
        })
        |> put_in(["resources", Access.at(0), "interfaces", Access.at(0), "vlans"], [])

      assert %{"status" => "accepted"} =
               build_conn()
               |> authorize(token)
               |> post(~p"/api/v1/observations", complete)
               |> json_response(202)

      assert Topology.list_current_interface_vlan_memberships(scope, interface.id) == []
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

    test "validates VLAN membership and logical interface relationship payloads" do
      %{source: source, token: token} = source_fixture()

      invalid_vlan =
        source
        |> valid_observation_payload(%{"observation_id" => "invalid-vlan-membership"})
        |> put_in(
          ["resources", Access.at(0), "interfaces", Access.at(0), "vlan_mode"],
          "access"
        )
        |> put_in(
          ["resources", Access.at(0), "interfaces", Access.at(0), "vlans"],
          [%{"vid" => 10, "tagging_mode" => "tagged"}]
        )

      response =
        build_conn()
        |> authorize(token)
        |> post(~p"/api/v1/observations", invalid_vlan)
        |> json_response(422)

      assert %{"status" => "rejected", "errors" => vlan_errors} = response
      assert Enum.any?(vlan_errors, &(&1["path"] == "resources.0.interfaces.0.vlans"))

      self_relationship =
        source
        |> valid_observation_payload(%{"observation_id" => "self-interface-relationship"})
        |> put_in(
          ["resources", Access.at(0), "interfaces", Access.at(0), "relationships"],
          [%{"target" => "eth0", "kind" => "peer"}]
        )

      response =
        build_conn()
        |> authorize(token)
        |> post(~p"/api/v1/observations", self_relationship)
        |> json_response(422)

      assert %{"status" => "rejected", "errors" => relationship_errors} = response

      assert Enum.any?(
               relationship_errors,
               &(&1["path"] == "resources.0.interfaces.0.relationships")
             )

      assert Repo.aggregate(Observation, :count) == 0
    end

    test "accepts LLDP neighbor evidence through observation reconciliation" do
      %{source: source, token: token} = source_fixture()

      payload =
        source
        |> valid_observation_payload(%{"observation_id" => "lldp-neighbor"})
        |> put_in(
          ["resources", Access.at(0), "interfaces", Access.at(0), "neighbors"],
          [
            %{
              "protocol" => "lldp",
              "remote_chassis_id" => "02:00:00:00:00:02",
              "remote_chassis_id_kind" => "mac_address",
              "remote_system_name" => "switch-01",
              "remote_port_id" => "Ethernet1",
              "remote_port_id_kind" => "name",
              "ttl_seconds" => 120,
              "metadata" => %{"source" => "lldpd"}
            }
          ]
        )

      response =
        build_conn()
        |> authorize(token)
        |> post(~p"/api/v1/observations", payload)
        |> json_response(202)

      assert response["status"] == "accepted"
      evidence = Repo.one!(InterfaceNeighborEvidence)
      assert evidence.protocol == "lldp"
      assert evidence.remote_system_name == "switch-01"
      assert evidence.metadata == %{"source" => "lldpd"}
    end

    test "rejects null, blank, malformed, and invalid-completeness topology fields safely" do
      %{source: source, token: token} = source_fixture()
      long_unicode_scope = String.duplicate("e\u0301", 128)

      cases = [
        {"null-vlans",
         fn payload ->
           put_in(payload, ["resources", Access.at(0), "interfaces", Access.at(0), "vlans"], nil)
         end},
        {"null-relationships",
         fn payload ->
           put_in(
             payload,
             ["resources", Access.at(0), "interfaces", Access.at(0), "relationships"],
             nil
           )
         end},
        {"null-neighbors",
         fn payload ->
           put_in(
             payload,
             ["resources", Access.at(0), "interfaces", Access.at(0), "neighbors"],
             nil
           )
         end},
        {"invalid-neighbor-ttl",
         fn payload ->
           put_in(
             payload,
             ["resources", Access.at(0), "interfaces", Access.at(0), "neighbors"],
             [
               %{
                 "protocol" => "lldp",
                 "remote_chassis_id" => "switch",
                 "remote_port_id" => "eth0",
                 "ttl_seconds" => 0
               }
             ]
           )
         end},
        {"duplicate-neighbor-endpoint",
         fn payload ->
           neighbor = %{
             "protocol" => "cdp",
             "remote_chassis_id" => "switch",
             "remote_port_id" => "Gi1/0/1",
             "ttl_seconds" => 180
           }

           put_in(
             payload,
             ["resources", Access.at(0), "interfaces", Access.at(0), "neighbors"],
             [neighbor, Map.put(neighbor, "remote_chassis_id", " switch ")]
           )
         end},
        {"malformed-vlan",
         fn payload ->
           put_in(payload, ["resources", Access.at(0), "interfaces", Access.at(0), "vlans"], [
             "invalid"
           ])
         end},
        {"null-vlan-metadata",
         fn payload ->
           put_in(payload, ["resources", Access.at(0), "interfaces", Access.at(0), "vlans"], [
             %{"vid" => 10, "tagging_mode" => "tagged", "metadata" => nil}
           ])
         end},
        {"blank-vlan-identity",
         fn payload ->
           put_in(payload, ["resources", Access.at(0), "interfaces", Access.at(0), "vlans"], [
             %{"key" => " ", "scope" => " ", "vid" => 10, "tagging_mode" => "tagged"}
           ])
         end},
        {"null-vlan-key",
         fn payload ->
           put_in(payload, ["resources", Access.at(0), "interfaces", Access.at(0), "vlans"], [
             %{"key" => nil, "vid" => 10, "tagging_mode" => "tagged"}
           ])
         end},
        {"null-vlan-scope",
         fn payload ->
           put_in(payload, ["resources", Access.at(0), "interfaces", Access.at(0), "vlans"], [
             %{"scope" => nil, "vid" => 10, "tagging_mode" => "tagged"}
           ])
         end},
        {"overlong-unicode-vlan-scope",
         fn payload ->
           put_in(payload, ["resources", Access.at(0), "interfaces", Access.at(0), "vlans"], [
             %{"scope" => long_unicode_scope, "vid" => 10, "tagging_mode" => "tagged"}
           ])
         end},
        {"oversized-vlan-key",
         fn payload ->
           put_in(payload, ["resources", Access.at(0), "interfaces", Access.at(0), "vlans"], [
             %{
               "key" => String.duplicate("e\u0301", 1_001),
               "vid" => 10,
               "tagging_mode" => "tagged"
             }
           ])
         end},
        {"duplicate-normalized-vlan-key",
         fn payload ->
           put_in(payload, ["resources", Access.at(0), "interfaces", Access.at(0), "vlans"], [
             %{"key" => "port-vlan", "vid" => 10, "tagging_mode" => "tagged"},
             %{"key" => " port-vlan ", "vid" => 20, "tagging_mode" => "tagged"}
           ])
         end},
        {"duplicate-interface-name",
         fn payload ->
           put_in(payload, ["resources", Access.at(0), "interfaces"], [
             %{"name" => "eth0", "vlan_mode" => "trunk"},
             %{"name" => " eth0 ", "vlan_mode" => "access"}
           ])
         end},
        {"invalid-completeness",
         fn payload ->
           Map.put(payload, "section_completeness", %{"interface_vlans" => nil})
         end},
        {"unknown-completeness",
         fn payload ->
           Map.put(payload, "section_completeness", %{"unknown" => true})
         end}
      ]

      for {name, mutate} <- cases do
        payload =
          source
          |> valid_observation_payload(%{"observation_id" => name})
          |> mutate.()

        response =
          build_conn()
          |> authorize(token)
          |> post(~p"/api/v1/observations", payload)
          |> json_response(422)

        assert %{"status" => "rejected", "errors" => [_ | _]} = response
      end

      assert Repo.aggregate(Observation, :count) == 0
    end

    test "accepts a VLAN scope at the 255-code-point storage boundary" do
      %{source: source} = source_fixture()

      payload =
        source
        |> valid_observation_payload(%{"observation_id" => "max-vlan-scope"})
        |> put_in(["resources", Access.at(0), "interfaces", Access.at(0), "vlans"], [
          %{
            "key" => String.duplicate("k", 2_000),
            "scope" => String.duplicate("x", 255),
            "vid" => 10,
            "tagging_mode" => "tagged"
          }
        ])

      assert {:ok, _attrs} = AgentPayload.validate_observation(payload, source)
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

    test "rejects non-object identifiers and malformed attribute containers without crashing" do
      %{source: source, token: token} = source_fixture()

      resources = [
        %{"kind" => "server", "identifiers" => ["compute-01"], "attributes" => nil},
        %{
          "kind" => "server",
          "identifiers" => %{"hostname" => "compute-01"},
          "attributes" => ["compute-01"]
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

        assert Enum.any?(
                 errors,
                 &(&1["path"] in ~w(resources.0.identifiers resources.0.attributes))
               )
      end

      assert Repo.aggregate(Observation, :count) == 0
    end

    test "rejects explicit null attributes with valid identifiers" do
      %{source: source, token: token} = source_fixture()

      resource = %{
        "kind" => "server",
        "identifiers" => %{"hostname" => "compute-01"},
        "attributes" => nil
      }

      response =
        build_conn()
        |> authorize(token)
        |> post(
          ~p"/api/v1/observations",
          valid_observation_payload(source, %{"resources" => [resource]})
        )
        |> json_response(422)

      assert %{"status" => "rejected", "errors" => errors} = response
      assert Enum.any?(errors, &(&1["path"] == "resources.0.attributes"))
      assert Repo.aggregate(Observation, :count) == 0
    end

    test "rejects top-level MAC identity with malformed interface containers without crashing" do
      %{source: source, token: token} = source_fixture()

      for interfaces <- [nil, %{"eth0" => %{}}, [nil, "eth0"]] do
        resource = %{
          "kind" => "server",
          "identifiers" => %{
            "hostname" => "compute-01",
            "mac_address" => "aa:bb:cc:dd:ee:ff"
          },
          "interfaces" => interfaces
        }

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

        if interfaces != nil do
          assert Enum.any?(errors, &String.starts_with?(&1["path"], "resources.0.interfaces"))
        end
      end

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

    test "accepts physical MAC identity while retaining non-ethernet interface evidence", %{
      conn: conn
    } do
      %{source: source, token: token} = source_fixture()

      payload =
        source
        |> valid_observation_payload()
        |> put_in(["resources", Access.at(0), "identifiers", "mac_address"], [
          "aa:bb:cc:dd:ee:ff"
        ])
        |> update_in(["resources", Access.at(0), "interfaces"], fn interfaces ->
          interfaces ++
            [
              %{
                "name" => "docker0",
                "kind" => "virtual",
                "status" => "up",
                "mac_address" => "02:42:ac:11:00:01",
                "addresses" => []
              },
              %{
                "name" => "bond0",
                "kind" => "bond",
                "status" => "up",
                "mac_address" => "02:42:ac:11:00:02",
                "addresses" => []
              },
              %{
                "name" => "unclassified0",
                "kind" => "unknown",
                "status" => "up",
                "mac_address" => "02:42:ac:11:00:03",
                "addresses" => []
              }
            ]
        end)

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
        |> put_in(["source"], %{})

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

    test "returns a stable failed reconciliation for a duplicate terminal result", %{conn: conn} do
      %{scope: scope, source: source, token: token} = source_fixture()
      payload = valid_observation_payload(source)
      {:ok, attrs} = AgentPayload.validate_observation(payload, source)
      {:ok, observation, :created} = Inventory.accept_observation(scope, source.id, attrs)
      completed_at = Renga.Time.utc_now_ms()

      {:ok, _result} =
        Inventory.create_observation_reconciliation(scope, observation.id, %{
          status: "failed",
          attempt: 1,
          errors: %{"processing" => "projection_failed"},
          started_at: completed_at,
          completed_at: completed_at
        })

      duplicate_conn =
        conn
        |> authorize(token)
        |> post(~p"/api/v1/observations", payload)

      assert %{
               "status" => "accepted",
               "duplicate" => true,
               "reconciliation" => %{
                 "status" => "failed",
                 "matched_resource_id" => nil,
                 "errors" => %{"processing" => "projection_failed"}
               },
               "observation" => %{"id" => observation_id}
             } = json_response(duplicate_conn, 200)

      assert observation_id == observation.id

      assert [%{attempt: 1, status: "failed"}] =
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
