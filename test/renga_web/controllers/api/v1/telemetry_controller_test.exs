defmodule RengaWeb.Api.V1.TelemetryControllerTest do
  @moduledoc """
  RFD 10 phase 4: power readings arrive in telemetry batches with a canonical
  identity and advance their series by event time.
  """

  use RengaWeb.ConnCase, async: true

  import Renga.AccountsFixtures
  import Renga.InventoryFixtures

  alias Renga.Accounts
  alias Renga.Inventory
  alias Renga.Inventory.Agent
  alias Renga.Inventory.AgentLease
  alias Renga.Inventory.Collectors
  alias Renga.Inventory.Observation
  alias Renga.Power.Reading
  alias Renga.Power.Readings
  alias Renga.Repo

  @installation_id "67e55044-10b1-426f-9247-bb680e5fe0c8"

  setup do
    user = user_fixture()
    organization = organization_fixture()
    organization_membership_fixture(user, organization, %{role: "admin"})
    scope = Accounts.scope_for_user(user, organization.id)
    {:ok, {_key, token}} = Inventory.create_intake_api_key(scope, %{name: "Fleet"})

    %{scope: scope, token: token}
  end

  describe "POST /api/v1/telemetry" do
    test "needs the installation to have checked in", %{token: token} do
      conn = post_batch(token, host_batch([sample()]))

      assert %{"errors" => [%{"path" => "installation_id"}]} = valid_api_response(conn, 409)
    end

    test "stores the host's readings under its own source without touching inventory", %{
      scope: scope,
      token: token
    } do
      check_in!(token)
      [agent] = Inventory.list_agents(scope)
      lease = Repo.get_by!(AgentLease, agent_id: agent.id)

      conn = post_batch(token, host_batch([sample(value: 412.5)]))

      assert %{
               "duplicate" => false,
               "batch" => %{"source_id" => source_id, "sample_count" => 1},
               "samples" => %{"current" => 1, "superseded" => 0, "rejected" => 0}
             } = valid_api_response(conn, 202)

      assert source_id == agent.source_id

      assert [reading] = Readings.list_source_readings(scope, source_id)
      assert reading.target == nil
      assert reading.sensor == "hwmon0/power1"
      assert reading.boundary == "host_input"
      assert reading.validity == "valid"
      assert Decimal.equal?(reading.value, Decimal.new("412.5"))
      assert reading.window_ms == 60_000
      assert reading.mapping_name == "hwmon"
      assert DateTime.compare(reading.fresh_until, ~U[2026-08-13 07:33:00Z]) == :eq

      # Telemetry is not a check-in or an inventory report.
      assert Repo.get_by!(AgentLease, agent_id: agent.id).renewed_at == lease.renewed_at
      assert Repo.aggregate(Observation, :count) == 0
    end

    test "the host's readings are about the resource its reports reconcile to", %{
      scope: scope,
      token: token
    } do
      check_in!(token)

      report = %{
        "observation_id" => "host-1",
        "observed_at" => "2026-08-13T07:30:00Z",
        "resources" => [
          %{"kind" => "server", "identifiers" => %{"machine_id" => "m-1"}, "attributes" => %{}}
        ]
      }

      observation =
        build_conn()
        |> put_req_header("authorization", "Bearer #{token}")
        |> put_req_header("x-renga-installation-id", @installation_id)
        |> post(~p"/api/v1/observations", report)

      assert %{"reconciliation" => %{"matched_resource_id" => resource_id}} =
               valid_api_response(observation, 202)

      valid_api_response(post_batch(token, host_batch([sample(value: 300)])), 202)

      assert %{^resource_id => [%{reading: reading}]} =
               Readings.for_resources(scope, [resource_id], ~U[2026-08-13 07:31:00Z])

      assert reading.sensor == "hwmon0/power1"
    end

    test "a collector's readings go to its stream, named by target", %{
      scope: scope,
      token: token
    } do
      check_in!(token)

      batch =
        host_batch([
          sample(target: "10.0.0.5", sensor: "outlet/3", boundary: "outlet", value: 120)
        ])
        |> Map.put("collector", %{"id" => "rack-pdus", "kind" => "power_poller"})

      conn = post_batch(token, batch)
      assert %{"batch" => %{"source_id" => stream_id}} = valid_api_response(conn, 202)

      assert [stream] = Collectors.list_streams(scope)
      assert stream.id == stream_id
      assert stream.kind == "power_poller"
      assert [%Reading{target: "10.0.0.5"}] = Readings.list_source_readings(scope, stream_id)
    end

    test "a power poller's readings are about the PDU its target reports", %{
      scope: scope,
      token: token
    } do
      collector = %{"id" => "rack-pdus", "kind" => "power_poller"}

      report = %{
        "observation_id" => "pdu-poll-1",
        "observed_at" => "2026-08-13T07:30:00Z",
        "scope" => "targets",
        "collector" => collector,
        "targets" => [%{"address" => "10.0.0.5", "status" => "reachable"}],
        "complete" => true,
        "resources" => [
          %{
            "kind" => "pdu",
            "target" => "10.0.0.5",
            "identifiers" => %{"serial_number" => "PDU-SER-1", "hostname" => "pdu-a1"},
            "attributes" => %{"vendor" => "Raritan", "model" => "PX3-5190R"},
            "interfaces" => []
          }
        ]
      }

      assert %{
               "reconciliation" => %{
                 "resources" => [%{"status" => "succeeded", "resource_id" => pdu_id}]
               }
             } =
               build_conn()
               |> put_req_header("authorization", "Bearer #{token}")
               |> put_req_header("x-renga-installation-id", @installation_id)
               |> post(~p"/api/v1/observations", report)
               |> valid_api_response(202)

      assert Inventory.get_resource!(scope, pdu_id).kind == "pdu"

      batch =
        host_batch([
          sample(
            target: "10.0.0.5",
            sensor: "outlet/3/active_power",
            boundary: "outlet",
            component: %{"kind" => "power_outlet", "name" => "3"},
            value: 120,
            mapping: %{"name" => "raritan_pdu2", "version" => 1}
          )
        ])
        |> Map.put("collector", collector)

      token |> post_batch(batch) |> valid_api_response(202)

      assert %{^pdu_id => [%{reading: %Reading{component_name: "3"}, eligible?: true}]} =
               Readings.for_resources(scope, [pdu_id], ~U[2026-08-13 07:31:00Z])
    end

    test "recent outlet and supply samples enter the correlation window", %{token: token} do
      check_in!(token)
      now = Renga.Time.utc_now_ms() |> DateTime.to_iso8601()

      batch =
        host_batch([
          sample(
            sensor: "PSU1/input",
            boundary: "supply_input",
            component: %{"kind" => "power_port", "name" => "PSU1"},
            event_at: now
          ),
          sample(sensor: "acpi", event_at: now),
          # Older than the window's 24 hours.
          sample(sensor: "PSU2/input", boundary: "supply_input")
        ])

      token |> post_batch(batch) |> valid_api_response(202)

      assert [%Renga.Power.CorrelationSample{sensor: "PSU1/input"}] =
               Repo.all(Renga.Power.CorrelationSample)
    end

    test "a replayed batch is accepted once, and a reused replay ID is a conflict", %{
      scope: scope,
      token: token
    } do
      check_in!(token)
      batch = host_batch([sample(value: 100)])

      assert %{"duplicate" => false, "batch" => %{"id" => id, "source_id" => source_id}} =
               valid_api_response(post_batch(token, batch), 202)

      replay = post_batch(token, batch)

      assert %{"duplicate" => true, "batch" => %{"id" => ^id}} =
               body = valid_api_response(replay, 200)

      refute Map.has_key?(body, "samples")

      changed = put_in(batch, ["samples", Access.at(0), "value"], 999)

      assert %{"errors" => [%{"path" => "replay_id"}]} =
               valid_api_response(post_batch(token, changed), 409)

      assert [reading] = Readings.list_source_readings(scope, source_id)
      assert Decimal.equal?(reading.value, Decimal.new(100))
    end

    test "a late replay is kept out of a newer current value", %{scope: scope, token: token} do
      check_in!(token)

      newer = sample(value: 300, event_at: "2026-08-13T07:35:00Z")
      older = sample(value: 200, event_at: "2026-08-13T07:30:00Z")

      assert %{"samples" => %{"current" => 1}} =
               valid_api_response(post_batch(token, host_batch([newer])), 202)

      assert %{"samples" => %{"current" => 0, "superseded" => 1}} =
               valid_api_response(post_batch(token, host_batch([older])), 202)

      [agent] = Inventory.list_agents(scope)
      assert [reading] = Readings.list_source_readings(scope, agent.source_id)
      assert Decimal.equal?(reading.value, Decimal.new(300))
      assert DateTime.compare(reading.event_at, ~U[2026-08-13 07:35:00Z]) == :eq

      # Within one batch the latest sample of a series wins too.
      batch =
        host_batch([
          sample(value: 500, event_at: "2026-08-13T07:40:00Z"),
          sample(value: 400, event_at: "2026-08-13T07:39:00Z")
        ])

      assert %{"samples" => %{"current" => 1, "superseded" => 1}} =
               valid_api_response(post_batch(token, batch), 202)

      assert [reading] = Readings.list_source_readings(scope, agent.source_id)
      assert Decimal.equal?(reading.value, Decimal.new(500))
    end

    test "a rolling average and an instantaneous value are separate series", %{
      scope: scope,
      token: token
    } do
      check_in!(token)

      instant =
        sample(
          value: 410,
          window: %{"start" => "2026-08-13T07:30:00Z", "end" => "2026-08-13T07:30:00Z"}
        )

      valid_api_response(post_batch(token, host_batch([sample(value: 400), instant])), 202)

      [agent] = Inventory.list_agents(scope)

      assert [%Reading{window_ms: 0}, %Reading{window_ms: 60_000}] =
               scope
               |> Readings.list_source_readings(agent.source_id)
               |> Enum.sort_by(& &1.window_ms)
    end

    test "unusable evidence is kept as invalid, never as zero", %{scope: scope, token: token} do
      check_in!(token)

      batch =
        host_batch([
          sample(sensor: "failed", status: "failed", value: nil),
          sample(sensor: "missing", status: "missing", value: nil),
          sample(sensor: "wrong-unit", unit: "VA", value: 400),
          sample(sensor: "negative", value: -5),
          sample(sensor: "no-value", value: nil),
          sample(
            sensor: "power-factor",
            quantity: "power_factor",
            unit: "1",
            value: 1.2
          ),
          sample(sensor: "supply", quantity: "state", unit: nil, value: nil, state: "ok")
        ])

      valid_api_response(post_batch(token, batch), 202)
      [agent] = Inventory.list_agents(scope)

      validity =
        scope
        |> Readings.list_source_readings(agent.source_id)
        |> Map.new(&{&1.sensor, {&1.validity, &1.value, &1.state}})

      assert validity == %{
               "failed" => {"failed", nil, nil},
               "missing" => {"missing", nil, nil},
               "wrong-unit" => {"invalid", nil, nil},
               "negative" => {"invalid", nil, nil},
               "no-value" => {"invalid", nil, nil},
               "power-factor" => {"invalid", nil, nil},
               "supply" => {"valid", nil, "ok"}
             }

      # A newer failure replaces a valid value: the latest is that there is none.
      valid_api_response(post_batch(token, host_batch([sample(sensor: "later", value: 10)])), 202)

      failed =
        sample(sensor: "later", status: "failed", value: nil, event_at: "2026-08-13T07:31:00Z")

      valid_api_response(post_batch(token, host_batch([failed])), 202)

      assert %Reading{validity: "failed", value: nil} =
               scope
               |> Readings.list_source_readings(agent.source_id)
               |> Enum.find(&(&1.sensor == "later"))
    end

    test "rejects samples from the future and malformed batches", %{scope: scope, token: token} do
      check_in!(token)
      future = DateTime.utc_now() |> DateTime.add(1, :hour) |> DateTime.to_iso8601()

      batch =
        host_batch([
          sample(sensor: "future", event_at: future),
          sample(sensor: "now", value: 1)
        ])

      assert %{"samples" => %{"current" => 1, "rejected" => 1}} =
               valid_api_response(post_batch(token, batch), 202)

      [agent] = Inventory.list_agents(scope)
      assert [%Reading{sensor: "now"}] = Readings.list_source_readings(scope, agent.source_id)

      for {payload, path} <- [
            {Map.put(host_batch([sample()]), "version", 2), "version"},
            {Map.delete(host_batch([sample()]), "replay_id"), "replay_id"},
            {host_batch([]), "samples"},
            {host_batch([sample(target: "10.0.0.5")]), "samples[0].target"},
            {host_batch([sample(boundary: "wall")]), "samples[0].boundary"},
            {host_batch([sample(boundary: "leg")]), "samples[0].leg"},
            {host_batch([sample(leg: "a")]), "samples[0].leg"},
            {host_batch([sample(value: "400")]), "samples[0].value"},
            {host_batch([sample(fresh_for_seconds: 0)]), "samples[0].fresh_for_seconds"},
            {host_batch([
               sample(
                 window: %{"start" => "2026-08-13T07:30:00Z", "end" => "2026-08-13T07:29:00Z"}
               )
             ]), "samples[0].window"},
            {Map.put(host_batch([sample(target: "x")]), "collector", %{
               "id" => "pdus",
               "kind" => "switch_poller"
             }), "collector.kind"},
            {Map.put(host_batch([sample()]), "collector", %{
               "id" => "pdus",
               "kind" => "power_poller"
             }), "samples[0].target"}
          ] do
        conn = post_batch(token, payload)
        assert %{"errors" => errors} = valid_api_response(conn, 422)
        assert Enum.any?(errors, &(&1["path"] == path)), "expected #{path} in #{inspect(errors)}"
      end
    end

    test "windows differing by milliseconds are separate series, up to a day long", %{
      scope: scope,
      token: token
    } do
      check_in!(token)
      start = "2026-08-13T07:30:00Z"

      batch =
        host_batch(
          for finish <- [
                start,
                "2026-08-13T07:30:00.500Z",
                "2026-08-13T07:31:00Z",
                "2026-08-13T07:31:00.500Z",
                "2026-08-14T07:30:00Z"
              ] do
            sample(window: %{"start" => start, "end" => finish}, event_at: finish)
          end
        )

      assert %{"samples" => %{"current" => 5}} = valid_api_response(post_batch(token, batch), 202)

      [agent] = Inventory.list_agents(scope)

      assert [0, 500, 60_000, 60_500, 86_400_000] ==
               scope |> Readings.list_source_readings(agent.source_id) |> Enum.map(& &1.window_ms)

      too_long = %{"start" => start, "end" => "2026-08-14T07:30:00.001Z"}
      batch = host_batch([sample(window: too_long)])
      assert %{"errors" => errors} = valid_api_response(post_batch(token, batch), 422)
      assert Enum.any?(errors, &(&1["path"] == "samples[0].window"))
    end

    test "a string fits its column, counted in code points", %{scope: scope, token: token} do
      check_in!(token)
      # 128 graphemes, but 256 code points.
      combining = String.duplicate("e\u0301", 128)

      for {payload, path} <- [
            {host_batch([sample(sensor: combining)]), "samples[0].sensor"},
            {Map.put(host_batch([sample()]), "replay_id", combining), "replay_id"},
            {host_batch([sample(sensor: "hwmon0\u0000power1")]), "samples[0].sensor"}
          ] do
        assert %{"errors" => errors} = valid_api_response(post_batch(token, payload), 422)
        assert Enum.any?(errors, &(&1["path"] == path)), "expected #{path} in #{inspect(errors)}"
      end

      [agent] = Inventory.list_agents(scope)
      assert Readings.list_source_readings(scope, agent.source_id) == []

      longest = String.duplicate("e\u0301", 127) <> "e"
      valid_api_response(post_batch(token, host_batch([sample(sensor: longest)])), 202)
      assert [%Reading{sensor: ^longest}] = Readings.list_source_readings(scope, agent.source_id)
    end

    test "accepts the batches the agent's contract test checks", %{token: token} do
      check_in!(token)

      assert [_ | _] =
               bodies =
               "test/fixtures/openapi/accepted_telemetry.json" |> File.read!() |> Jason.decode!()

      for body <- bodies do
        assert %{"duplicate" => false, "samples" => %{"rejected" => 0}} =
                 valid_api_response(post_batch(token, body), 202)
      end
    end

    test "a disabled agent's telemetry is refused", %{scope: scope, token: token} do
      check_in!(token)
      [agent] = Inventory.list_agents(scope)
      agent |> Ecto.Changeset.change(status: "disabled") |> Repo.update!()
      assert %Agent{status: "disabled"} = Repo.get!(Agent, agent.id)

      assert %{"errors" => [%{"path" => "installation_id"}]} =
               valid_api_response(post_batch(token, host_batch([sample()])), 403)
    end
  end

  describe "eligibility" do
    test "a valid reading counts until its freshness window passes" do
      reading = %Reading{validity: "valid", fresh_until: ~U[2026-08-13 07:33:00Z]}

      assert Reading.eligible?(reading, ~U[2026-08-13 07:32:59Z])
      assert Reading.ineligibility(reading, ~U[2026-08-13 07:32:59Z]) == nil
      refute Reading.eligible?(reading, ~U[2026-08-13 07:33:00Z])
      assert Reading.ineligibility(reading, ~U[2026-08-13 07:33:00Z]) == :stale

      for validity <- ~w(missing failed invalid) do
        reading = %{reading | validity: validity}
        refute Reading.eligible?(reading, ~U[2026-08-13 07:30:00Z])

        assert Reading.ineligibility(reading, ~U[2026-08-13 07:30:00Z]) ==
                 String.to_atom(validity)
      end
    end
  end

  defp check_in!(token) do
    conn =
      build_conn()
      |> put_req_header("authorization", "Bearer #{token}")
      |> put_req_header("x-renga-installation-id", @installation_id)
      |> post(~p"/api/v1/agent/checkins", %{})

    valid_api_response(conn, 202)
  end

  defp post_batch(token, payload) do
    build_conn()
    |> put_req_header("authorization", "Bearer #{token}")
    |> put_req_header("x-renga-installation-id", @installation_id)
    |> put_req_header("content-type", "application/json")
    |> post(~p"/api/v1/telemetry", Jason.encode!(payload))
  end

  defp host_batch(samples) do
    %{
      "version" => 1,
      "replay_id" => "batch-#{System.unique_integer([:positive])}",
      "samples" => samples
    }
  end

  defp sample(overrides \\ []) do
    event_at = Keyword.get(overrides, :event_at, "2026-08-13T07:30:00Z")

    %{
      "sensor" => "hwmon0/power1",
      "boundary" => "host_input",
      "quantity" => "real_power",
      "unit" => "W",
      "value" => 400,
      "window" => %{"start" => "2026-08-13T07:29:00Z", "end" => "2026-08-13T07:30:00Z"},
      "event_at" => event_at,
      "mapping" => %{"name" => "hwmon", "version" => 1},
      "fresh_for_seconds" => 180
    }
    |> Map.merge(
      overrides
      |> Keyword.delete(:event_at)
      |> Map.new(fn {key, value} -> {Atom.to_string(key), value} end)
    )
  end
end
