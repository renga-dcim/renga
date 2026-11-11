defmodule RengaWeb.Api.V1.IntakeCapacityTest do
  use RengaWeb.ConnCase, async: false

  import Ecto.Query
  import Renga.AccountsFixtures
  import Renga.InventoryFixtures

  alias Renga.{Accounts, IntakeCapacity, Inventory, Limits}
  alias RengaWeb.IntakeAuth

  defp fleet do
    organization = organization_fixture()
    user = user_fixture()
    organization_membership_fixture(user, organization, %{role: "owner"})
    scope = Accounts.scope_for_user(user, organization.id)
    {:ok, {key, token}} = Inventory.create_intake_api_key(scope, %{name: "Fleet"})
    %{organization: organization, key: key, token: token, installation: Ecto.UUID.generate()}
  end

  defp request(fleet, path) do
    build_conn(:post, path)
    |> put_req_header("authorization", "Bearer #{fleet.token}")
    |> put_req_header("x-renga-installation-id", fleet.installation)
  end

  test "the endpoint rejects an oversized observation before parsing or domain writes" do
    fleet = fleet()
    body = Jason.encode!(%{padding: String.duplicate("x", 256_001)})

    for path <- ["/api/v1/observations", "/api/v1/%6fbservations"] do
      conn =
        fleet
        |> request(path)
        |> put_req_header("content-type", "application/json")
        |> post(path, body)

      # Rejection precedes the router, including its path decoding.
      assert %{"status" => "rejected"} = valid_api_response(conn, 413, "createObservation")
    end

    refute Renga.Repo.exists?(
             from observation in Renga.Inventory.Observation,
               where: observation.organization_id == ^fleet.organization.id
           )
  end

  test "authenticated requests expose organization-tagged bytes and database time" do
    fleet = fleet()
    parent = self()
    handler = "capacity-metrics-#{Ecto.UUID.generate()}"
    events = [[:renga, :intake, :request], [:renga, :intake, :database]]

    :ok =
      :telemetry.attach_many(
        handler,
        events,
        fn event, values, metadata, _ ->
          send(parent, {event, values, metadata})
        end,
        nil
      )

    on_exit(fn -> :telemetry.detach(handler) end)
    body = Jason.encode!(%{capabilities: ["inventory.collect@1"]})

    conn =
      fleet
      |> request("/api/v1/agent/checkins")
      |> put_req_header("content-type", "application/json")
      |> post("/api/v1/agent/checkins", body)

    assert %{"status" => "accepted"} = valid_api_response(conn, 202)
    org = fleet.organization.id

    assert_receive {[:renga, :intake, :request], %{count: 1, bytes: bytes},
                    %{organization_id: ^org, status: 202}}

    assert bytes == byte_size(body)
    assert_receive {[:renga, :intake, :database], %{query_time: time}, %{organization_id: ^org}}
    assert time >= 0
  end

  test "a bulk rejection leaves maintenance and another organization's bulk lane usable" do
    noisy = fleet()
    quiet = fleet()

    :ok =
      Limits.set(
        noisy.organization,
        [intake_bulk_rate: 0],
        Renga.DeploymentAudit.operator("test")
      )

    rejected = noisy |> request("/api/v1/observations") |> IntakeAuth.call([])
    assert rejected.status == 429
    assert [retry] = get_resp_header(rejected, "retry-after")
    assert String.to_integer(retry) > 0

    for {fleet, path} <- [
          {noisy, "/api/v1/agent/checkins"},
          {noisy, "/api/v1/agent/jobs/#{Ecto.UUID.generate()}/events"},
          {quiet, "/api/v1/observations"}
        ] do
      admitted = fleet |> request(path) |> IntakeAuth.call([])
      refute admitted.halted
      send_resp(admitted, 204, "")
    end

    assert noisy
           |> request("/api/v1/agent/jobs/lease")
           |> IntakeAuth.call([])
           |> Map.fetch!(:status) == 429

    assert noisy
           |> request("/api/v1/agent/jobs/#{Ecto.UUID.generate()}/claims")
           |> IntakeAuth.call([])
           |> Map.fetch!(:status) == 429
  end

  test "one installation's maintenance rate does not consume another installation's allowance" do
    fleet = fleet()

    :ok =
      Limits.set(
        fleet.organization,
        [installation_intake_rate: 1],
        Renga.DeploymentAudit.operator("test")
      )

    first = fleet |> request("/api/v1/agent/checkins") |> IntakeAuth.call([])
    refute first.halted
    send_resp(first, 204, "")

    rejected = fleet |> request("/api/v1/agent/checkins") |> IntakeAuth.call([])
    assert rejected.status == 429

    for {caller, path} <- [
          {%{fleet | installation: Ecto.UUID.generate()}, "/api/v1/agent/checkins"},
          {fleet, "/api/v1/observations"}
        ] do
      admitted = caller |> request(path) |> IntakeAuth.call([])
      refute admitted.halted
      send_resp(admitted, 204, "")
    end
  end

  test "a raised override cannot bypass lease backpressure at the hard maintenance cap" do
    fleet = fleet()

    :ok =
      Limits.set(
        fleet.organization,
        [intake_concurrency: IntakeCapacity.lane_size(:maintenance) * 2],
        Renga.DeploymentAudit.operator("test")
      )

    held =
      for _ <- 1..IntakeCapacity.organization_size() do
        conn = fleet |> request("/api/v1/agent/checkins") |> IntakeAuth.call([])
        refute conn.halted
        conn
      end

    try do
      for path <- [
            "/api/v1/agent/jobs/lease",
            "/api/v1/agent/jobs/#{Ecto.UUID.generate()}/claims"
          ] do
        rejected = fleet |> request(path) |> IntakeAuth.call([])
        assert rejected.status == 429
      end
    after
      Enum.each(held, &send_resp(&1, 204, ""))
    end
  end

  test "a permit remains held until the response, and a crashed owner cannot leak it" do
    fleet = fleet()

    :ok =
      Limits.set(
        fleet.organization,
        [intake_concurrency: 1],
        Renga.DeploymentAudit.operator("test")
      )

    admitted = fleet |> request("/api/v1/observations") |> IntakeAuth.call([])
    refute admitted.halted

    assert fleet |> request("/api/v1/observations") |> IntakeAuth.call([]) |> Map.fetch!(:status) ==
             429

    send_resp(admitted, 204, "")
    again = fleet |> request("/api/v1/observations") |> IntakeAuth.call([])
    refute again.halted
    send_resp(again, 204, "")

    parent = self()

    pid =
      spawn(fn ->
        {:ok, _} = IntakeCapacity.acquire({:test, parent}, 1)
        send(parent, :held)

        receive do
          :stop -> :ok
        end
      end)

    assert_receive :held
    assert :full = IntakeCapacity.acquire({:test, parent}, 1)
    monitor = Process.monitor(pid)
    send(pid, :stop)
    assert_receive {:DOWN, ^monitor, :process, ^pid, :normal}
    # Ordering a call after DOWN processing makes reclamation observable.
    eventually_acquire({:test, parent})
  end

  defp eventually_acquire(key, attempts \\ 20) do
    case IntakeCapacity.acquire(key, 1) do
      {:ok, permit} ->
        IntakeCapacity.release(permit)

      :full when attempts > 0 ->
        Process.sleep(5)
        eventually_acquire(key, attempts - 1)
    end
  end

  test "the bounded lookup lane rejects before touching a database and reserves maintenance lookup" do
    permits =
      for _ <- 1..IntakeCapacity.lane_size(:authentication) do
        {:ok, ref} =
          IntakeCapacity.acquire(
            {:authentication, :bulk},
            IntakeCapacity.lane_size(:authentication)
          )

        ref
      end

    try do
      conn =
        build_conn(:post, "/api/v1/observations")
        |> put_req_header("authorization", "Bearer renga_intake_invalid")
        |> put_req_header("x-renga-installation-id", Ecto.UUID.generate())
        |> IntakeAuth.call([])

      assert conn.status == 429

      # Same invalid caller in the maintenance lookup lane can still be
      # judged (401), rather than inheriting the bulk overload (429).
      conn =
        build_conn(:post, "/api/v1/agent/checkins")
        |> put_req_header("authorization", "Bearer renga_intake_invalid")
        |> put_req_header("x-renga-installation-id", Ecto.UUID.generate())
        |> IntakeAuth.call([])

      assert conn.status == 401
    after
      Enum.each(permits, &IntakeCapacity.release/1)
    end
  end
end
