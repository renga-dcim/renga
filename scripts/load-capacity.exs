# Run only against the disposable local test database:
# nix develop --command env MIX_ENV=test MIX_TEST_PARTITION=_capacity mix run --no-start scripts/load-capacity.exs
# Uses the complete Endpoint (body parser, auth, admission, controller and
# reconciliation) and real PostgreSQL, not a simulated limiter or mocked Repo.
defmodule Renga.CapacityLoad do
  import Ecto.Query
  import Renga.AccountsFixtures
  import Renga.InventoryFixtures
  alias Renga.{Accounts, Inventory, Repo}

  @hosts 3_000
  @baseline_seconds 60
  @enrollment_seconds 300

  def run do
    unless Mix.env() == :test, do: raise("capacity load must use the disposable test database")
    repo_config = Application.fetch_env!(:renga, Repo)

    unless String.starts_with?(repo_config[:database], "renga_test_capacity"),
      do:
        raise(
          "use MIX_TEST_PARTITION=_capacity; this script retains its disposable database for inspection"
        )

    pool = String.to_integer(System.get_env("LOAD_POOL_SIZE", "64"))
    # Sandbox auto-checkout pins a connection to each process for its entire
    # lifetime. A multi-minute run needs the production checkout semantics.
    Application.put_env(
      :renga,
      Repo,
      Keyword.merge(repo_config, pool_size: pool, pool: DBConnection.ConnectionPool)
    )

    Application.put_env(:renga, :intake_contact_worker_enabled, true)

    Application.put_env(
      :renga,
      RengaWeb.Endpoint,
      Keyword.put(Application.fetch_env!(:renga, RengaWeb.Endpoint), :server, false)
    )

    Mix.Task.run("app.start")
    Logger.configure(level: :error)
    :ets.new(__MODULE__, [:named_table, :public])

    :telemetry.attach(
      "capacity-load-rejections",
      [:renga, :intake, :admission_rejected],
      &__MODULE__.record_rejection/4,
      nil
    )

    fleet = fleet("large-site")
    quiet = fleet("quiet-neighbor")

    reuse? = System.get_env("LOAD_REUSE") == "true"

    hosts =
      if reuse?,
        do: existing_hosts(fleet),
        else: for(n <- 1..@hosts, do: {n, Ecto.UUID.generate()})

    unless length(hosts) == @hosts, do: raise("the fixture must contain exactly #{@hosts} hosts")
    IO.puts("Seeding #{@hosts} real hosts, four NICs and twelve components each")

    seed =
      if reuse? do
        %{name: "seed", reused: true}
      else
        seed =
          phase(
            "seed",
            hosts,
            fn {n, id} -> [checkin(fleet, id), observation(fleet, n, id)] end,
            1
          )

        assert_accepted!(seed)
        seed
      end

    # Agents default to hourly inventory and 60-second check-ins. Stable
    # evenly spread offsets model scheduled jitter rather than a stampede.
    baseline_events =
      for(
        {n, id} <- hosts,
        do: {div((n - 1) * @baseline_seconds * 1_000, @hosts), {:checkin, n, id}}
      ) ++
        for {n, id} <- Enum.take(hosts, div(@hosts, 60)),
            do: {(n - 1) * 1_200, {:observation, n, id}}

    baseline = scheduled("normal_schedule", baseline_events, fleet)

    reenrolled = Enum.map(hosts, fn {n, _} -> {n, Ecto.UUID.generate()} end)

    enrollment_events =
      for {n, id} <- reenrolled,
          do: {div((n - 1) * @enrollment_seconds * 1_000, @hosts), {:enroll, n, id}}

    maintenance =
      for minute <- 0..4,
          {n, id} <- hosts,
          minute * 60_000 + div((n - 1) * 60_000, @hosts) <
            div((n - 1) * @enrollment_seconds * 1_000, @hosts),
          do: {minute * 60_000 + div((n - 1) * 60_000, @hosts), {:checkin, n, id}}

    new_maintenance =
      for minute <- 1..4,
          {n, id} <- reenrolled,
          minute * 60_000 + div((n - 1) * 60_000, @hosts) >
            div((n - 1) * @enrollment_seconds * 1_000, @hosts),
          do: {minute * 60_000 + div((n - 1) * 60_000, @hosts), {:checkin, n, id}}

    enrollment =
      scheduled("full_reenrollment", enrollment_events ++ maintenance ++ new_maintenance, fleet)

    # A deliberately saturated admitted bulk operation, not just a low
    # configured rate. Every quiet request runs while the noisy permits
    # remain held; reports and check-ins use a separate reserved lane.
    limits = Renga.IntakeCapacity.limits(fleet.organization.id)

    held =
      for _ <- 1..limits.intake_concurrency do
        {:ok, ref} =
          Renga.IntakeCapacity.admit(fleet.organization.id, "noisy-load", :bulk, limits)

        ref
      end

    neighbor =
      try do
        phase(
          "noisy_neighbor_control",
          1..100,
          fn n ->
            id = Ecto.UUID.generate()

            noisy =
              request(fleet, id, "/api/v1/agent/jobs/lease", %{
                capabilities: ["inventory.collect@1"],
                limit: 1
              })

            unless noisy.status == 429, do: raise("noisy organization was not backpressured")
            [checkin(quiet, id), observation(quiet, 100_000 + n, id)]
          end,
          1
        )
      after
        Enum.each(held, &Renga.IntakeCapacity.release/1)
      end

    result = %{
      hosts: @hosts,
      pool_size: pool,
      baseline_seconds: @baseline_seconds,
      enrollment_seconds: @enrollment_seconds,
      phases: [seed, baseline, enrollment, neighbor]
    }

    IO.puts(Jason.encode!(result, pretty: true))
    Enum.each([baseline, enrollment, neighbor], &assert_accepted!/1)
  end

  defp fleet(name) do
    existing =
      if System.get_env("LOAD_REUSE") == "true",
        do: Repo.get_by(Renga.Accounts.Organization, name: "Capacity #{name}")

    {organization, user} =
      if existing do
        membership =
          Repo.get_by!(Renga.Accounts.OrganizationMembership, organization_id: existing.id)
          |> Repo.preload(:user)

        {existing, membership.user}
      else
        organization = organization_fixture(%{name: "Capacity #{name}"})
        user = user_fixture()
        organization_membership_fixture(user, organization, %{role: "owner"})
        {organization, user}
      end

    {:ok, {_key, token}} =
      Inventory.create_intake_api_key(Accounts.scope_for_user(user, organization.id), %{
        name: "Load"
      })

    %{organization: organization, user: user, token: token}
  end

  defp existing_hosts(fleet) do
    from(observation in Renga.Inventory.Observation,
      join: agent in Renga.Inventory.Agent,
      on: agent.source_id == observation.source_id,
      where: observation.organization_id == ^fleet.organization.id,
      select:
        {fragment("?->'resources'->0->'identifiers'->>'machine_id'", observation.payload),
         agent.installation_id}
    )
    |> Repo.all()
    |> Enum.map(fn {"capacity-machine-" <> n, id} -> {String.to_integer(n), id} end)
    |> Enum.uniq_by(&elem(&1, 0))
    |> Enum.sort()
  end

  defp scheduled(name, events, fleet) do
    started = System.monotonic_time(:millisecond)

    phase(
      name,
      Enum.sort(events),
      fn {offset, {kind, n, id}} ->
        Process.sleep(max(started + offset - System.monotonic_time(:millisecond), 0))

        case kind do
          :enroll -> [checkin(fleet, id), observation(fleet, n, id)]
          :checkin -> [checkin(fleet, id)]
          :observation -> [observation(fleet, n, id)]
        end
      end,
      256
    )
  end

  defp phase(name, events, operation, concurrency) do
    started = System.monotonic_time(:millisecond)
    :ets.delete_all_objects(__MODULE__)

    values =
      events
      |> Task.async_stream(operation,
        max_concurrency: concurrency,
        ordered: false,
        timeout: :infinity
      )
      |> Enum.flat_map(fn {:ok, results} -> results end)

    times = values |> Enum.map(& &1.ms) |> Enum.sort()

    summary = %{
      name: name,
      requests: length(values),
      elapsed_ms: System.monotonic_time(:millisecond) - started,
      statuses: Enum.frequencies_by(values, & &1.status),
      rejected_routes:
        values |> Enum.filter(&(&1.status == 429)) |> Enum.frequencies_by(& &1.path),
      p95_ms: Enum.at(times, trunc(length(times) * 0.95)),
      p99_ms: Enum.at(times, min(trunc(length(times) * 0.99), length(times) - 1)),
      admission_rejections: Map.new(:ets.tab2list(__MODULE__)),
      failed_reconciliations: Enum.count(values, & &1.failed_reconciliation)
    }

    IO.puts(Jason.encode!(summary))
    summary
  end

  def record_rejection(_event, _measurements, metadata, _config) do
    key = "#{metadata.lane}:#{metadata.reason}"
    :ets.update_counter(__MODULE__, key, {2, 1}, {key, 0})
  end

  defp assert_accepted!(result) do
    unless Enum.all?(result.statuses, fn {status, _} -> status in [200, 202] end) and
             result.failed_reconciliations == 0,
           do: raise("load phase #{result.name} failed; see status/reconciliation totals")
  end

  defp checkin(fleet, id),
    do:
      request(fleet, id, "/api/v1/agent/checkins", %{
        capabilities: ["inventory.collect@1"],
        metadata: %{hostname: "compute", agent_version: "load"}
      })

  defp observation(fleet, n, id) do
    request(fleet, id, "/api/v1/observations", %{
      observation_id: Ecto.UUID.generate(),
      observed_at: DateTime.to_iso8601(Renga.Time.utc_now_ms()),
      resources: [
        %{
          kind: "server",
          identifiers: %{hostname: "compute-#{n}", machine_id: "capacity-machine-#{n}"},
          attributes: %{hostname: "compute-#{n}", vendor: "Dell Inc.", model: "PowerEdge R760"},
          interfaces:
            for(
              port <- 0..3,
              do: %{name: "eth#{port}", kind: "ethernet", status: "up", mac_address: mac(n, port)}
            ),
          components:
            for(
              slot <- 0..11,
              do: %{
                kind: "memory",
                slot: "DIMM#{slot}",
                attributes: %{
                  size_bytes: 34_359_738_368,
                  vendor: "Samsung",
                  serial_number: "#{n}-#{slot}"
                }
              }
            )
        }
      ]
    })
  end

  defp mac(n, port) do
    [2, div(n, 65_536), div(rem(n, 65_536), 256), rem(n, 256), 0, port]
    |> Enum.map_join(":", &(Integer.to_string(&1, 16) |> String.pad_leading(2, "0")))
  end

  defp request(fleet, installation, path, body) do
    started = System.monotonic_time(:millisecond)

    conn =
      Plug.Test.conn(:post, path, Jason.encode!(body))
      |> Plug.Conn.put_req_header("content-type", "application/json")
      |> Plug.Conn.put_req_header("authorization", "Bearer #{fleet.token}")
      |> Plug.Conn.put_req_header("x-renga-installation-id", installation)
      |> RengaWeb.Endpoint.call([])

    response = Jason.decode!(conn.resp_body)

    %{
      status: conn.status,
      path: path,
      ms: System.monotonic_time(:millisecond) - started,
      failed_reconciliation: get_in(response, ["reconciliation", "status"]) == "failed"
    }
  end
end

Renga.CapacityLoad.run()
