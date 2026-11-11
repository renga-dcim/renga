# Run only against the disposable local test database:
# nix develop --command env MIX_ENV=test MIX_TEST_PARTITION=_capacity mix run --no-start scripts/load-capacity.exs
# Uses the complete Endpoint (body parser, auth, admission, controller and
# durable acceptance) and the autonomous executor against real PostgreSQL.
# Exploratory only: stage 2/3 and immutable topology are not exercised.
defmodule Renga.CapacityLoad do
  import Ecto.Query
  import Renga.AccountsFixtures
  import Renga.InventoryFixtures
  alias Renga.{Accounts, Inventory, Repo}
  alias Renga.Inventory.{Agent, Observation, ReconciliationLane, ReconciliationWork}

  @hosts String.to_integer(System.get_env("LOAD_HOSTS", "3000"))
  @baseline_seconds String.to_integer(System.get_env("LOAD_BASELINE_SECONDS", "60"))
  @enrollment_seconds String.to_integer(System.get_env("LOAD_ENROLLMENT_SECONDS", "300"))
  @drain_ms String.to_integer(System.get_env("LOAD_DRAIN_TIMEOUT_MS", "300000"))
  @harness_sha256 Base.encode16(:crypto.hash(:sha256, File.read!(__ENV__.file)), case: :lower)

  def run do
    unless Mix.env() == :test, do: raise("capacity load must use the disposable test database")
    repo_config = Application.fetch_env!(:renga, Repo)

    unless String.starts_with?(repo_config[:database], "renga_test_capacity"),
      do:
        raise(
          "use MIX_TEST_PARTITION=_capacity; this script retains its disposable database for inspection"
        )

    pool = String.to_integer(System.get_env("LOAD_POOL_SIZE", "10"))
    database_profile? = System.get_env("LOAD_DATABASE_PROFILE") == "true"

    parameters =
      if database_profile?,
        do:
          Keyword.merge(repo_config[:parameters] || [],
            track_io_timing: "on",
            track_wal_io_timing: "on"
          ),
        else: repo_config[:parameters]

    # Sandbox auto-checkout pins a connection to each process for its entire
    # lifetime. A multi-minute run needs the production checkout semantics.
    Application.put_env(
      :renga,
      Repo,
      Keyword.merge(repo_config,
        pool_size: pool,
        pool: DBConnection.ConnectionPool,
        parameters: parameters
      )
    )

    Application.put_env(:renga, :intake_contact_worker_enabled, true)

    Application.put_env(
      :renga,
      :reconciliation_worker_enabled,
      System.get_env("LOAD_RECONCILIATION_ENABLED") != "false"
    )

    Application.put_env(
      :renga,
      RengaWeb.Endpoint,
      Keyword.put(Application.fetch_env!(:renga, RengaWeb.Endpoint), :server, false)
    )

    Mix.Task.run("app.start")

    # Releases default to embedded code loading. Lazy mix-run loading made
    # first requests hold admission while waiting on the VM's code server.
    # Match release boot semantics without sending artificial warm-up traffic.
    # Mix and Hex are build tools, not applications shipped in the release.
    :ok =
      Application.started_applications()
      |> Enum.reject(fn {application, _description, _version} -> application in [:mix, :hex] end)
      |> Enum.flat_map(fn {application, _description, _version} ->
        Application.spec(application, :modules)
      end)
      |> :code.ensure_modules_loaded()

    Logger.configure(level: :error)

    if database_profile? do
      %{rows: [["on"]]} = Repo.query!("SHOW track_io_timing")
      %{rows: [["on"]]} = Repo.query!("SHOW track_wal_io_timing")
    end

    :ets.new(__MODULE__, [:named_table, :public])
    :ets.new(:capacity_queries, [:named_table, :public])
    :ets.new(:capacity_slow_queries, [:named_table, :public, :ordered_set])
    :ets.new(:capacity_receipts, [:named_table, :public])
    :ets.new(:capacity_successes, [:named_table, :public])

    if System.get_env("LOAD_PROFILE") == "true" do
      :telemetry.attach(
        "capacity-load-queries",
        [:renga, :repo, :query],
        &__MODULE__.record_query/4,
        nil
      )
    end

    :telemetry.attach(
      "capacity-load-rejections",
      [:renga, :intake, :admission_rejected],
      &__MODULE__.record_rejection/4,
      nil
    )

    fleet = fleet("large-site")
    quiet = fleet("quiet-neighbor")

    :persistent_term.put({__MODULE__, :organizations}, [
      fleet.organization.id,
      quiet.organization.id
    ])

    reuse? = System.get_env("LOAD_REUSE") == "true"

    hosts =
      if reuse?,
        do: existing_hosts(fleet),
        else: for(n <- 1..@hosts, do: {n, Ecto.UUID.generate()})

    unless length(hosts) == @hosts, do: raise("the fixture must contain exactly #{@hosts} hosts")
    IO.puts("Seeding #{@hosts} real hosts, four NICs and twelve components each")

    seed =
      if reuse? do
        pending =
          Repo.all(
            from work in ReconciliationWork,
              where:
                work.organization_id == ^fleet.organization.id and work.status != "succeeded",
              select: work.id
          )

        %{name: "seed", reused: true, processing: drain(pending, false)}
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

    seed = Map.put(seed, :canonical_projection, assert_resources!(fleet, @hosts))

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
      for minute <- 0..div(@enrollment_seconds - 1, 60),
          {n, id} <- hosts,
          minute * 60_000 + div((n - 1) * 60_000, @hosts) <
            div((n - 1) * @enrollment_seconds * 1_000, @hosts),
          do: {minute * 60_000 + div((n - 1) * 60_000, @hosts), {:checkin, n, id}}

    new_maintenance =
      for minute <- 1..max(div(@enrollment_seconds - 1, 60), 1),
          {n, id} <- reenrolled,
          minute * 60_000 + div((n - 1) * 60_000, @hosts) < @enrollment_seconds * 1_000,
          minute * 60_000 + div((n - 1) * 60_000, @hosts) >
            div((n - 1) * @enrollment_seconds * 1_000, @hosts),
          do: {minute * 60_000 + div((n - 1) * 60_000, @hosts), {:checkin, n, id}}

    enrollment =
      scheduled("full_reenrollment", enrollment_events ++ maintenance ++ new_maintenance, fleet)

    enrollment = Map.put(enrollment, :canonical_projection, assert_resources!(fleet, @hosts))

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

    processing_neighbor = processing_neighbor(fleet, quiet, reenrolled)
    final_backlog = backlog()

    unless Enum.all?(
             final_backlog,
             &(&1.pending_units == 0 and &1.pending_bytes == 0 and &1.outstanding == [])
           ),
           do: raise("run ended with an unresolved or charged obligation")

    result = %{
      exploratory: true,
      harness_sha256: @harness_sha256,
      hosts: @hosts,
      pool_size: pool,
      organizations: %{large_site: fleet.organization.id, quiet_neighbor: quiet.organization.id},
      intake_limits: limits,
      pending_work_limits: ReconciliationWork.limits(fleet.organization.id),
      final_backlog: final_backlog,
      application_modules_preloaded: true,
      baseline_seconds: @baseline_seconds,
      enrollment_seconds: @enrollment_seconds,
      phases: [seed, baseline, enrollment, neighbor, processing_neighbor]
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
    :ets.delete_all_objects(:capacity_queries)
    :ets.delete_all_objects(:capacity_slow_queries)

    sampler = Task.async(fn -> sample_backlog([]) end)

    {values, processing, samples} =
      try do
        values =
          events
          |> Task.async_stream(operation,
            max_concurrency: concurrency,
            ordered: false,
            timeout: :infinity
          )
          |> Enum.flat_map(fn {:ok, results} -> results end)

        acceptance_elapsed = System.monotonic_time(:millisecond) - started
        accepted = Enum.reject(values, &is_nil(&1.work_id))

        IO.puts(
          Jason.encode!(%{
            event: "acceptance_complete",
            phase: name,
            statuses: Enum.frequencies_by(values, & &1.status),
            receipts: length(accepted),
            elapsed_ms: acceptance_elapsed
          })
        )

        processing =
          drain(Enum.map(accepted, & &1.work_id))
          |> Map.put(:acceptance_elapsed_ms, acceptance_elapsed)

        {values, processing}
      after
        send(sampler.pid, :stop)
      end
      |> then(fn {values, processing} -> {values, processing, Task.await(sampler, 5_000)} end)

    times = values |> Enum.map(& &1.ms) |> Enum.sort()

    summary = %{
      name: name,
      requests: length(values),
      elapsed_ms: System.monotonic_time(:millisecond) - started,
      statuses: Enum.frequencies_by(values, & &1.status),
      rejected_routes:
        values |> Enum.filter(&(&1.status == 429)) |> Enum.frequencies_by(& &1.path),
      rejected_stages:
        values |> Enum.filter(&(&1.status == 429)) |> Enum.frequencies_by(& &1.rejection_stage),
      p95_ms: Enum.at(times, trunc(length(times) * 0.95)),
      p99_ms: Enum.at(times, min(trunc(length(times) * 0.99), length(times) - 1)),
      admission_rejections: Map.new(:ets.tab2list(__MODULE__)),
      processing: processing,
      backlog_samples: samples
    }

    if System.get_env("LOAD_PROFILE") == "true" do
      queries =
        :capacity_queries
        |> :ets.tab2list()
        |> Enum.sort_by(fn {_query, _count, time, _queue} -> time end, :desc)
        |> Enum.take(15)
        |> Enum.map(fn {query, count, time, queue} ->
          %{
            query: query,
            count: count,
            query_ms: System.convert_time_unit(time, :native, :millisecond),
            queue_ms: System.convert_time_unit(queue, :native, :millisecond)
          }
        end)

      slow_queries =
        :capacity_slow_queries
        |> :ets.tab2list()
        |> Enum.reverse()
        |> Enum.map(fn {{duration, _id}, at, query} ->
          %{query_ms: duration, phase_ms: at - started, query: query}
        end)

      IO.puts(Jason.encode!(%{profile_phase: name, queries: queries, slow_queries: slow_queries}))
    end

    IO.puts(Jason.encode!(summary))
    summary
  end

  def record_query(_event, measurements, %{query: query}, _config) do
    record_canonical_hold(query, measurements)

    :ets.update_counter(
      :capacity_queries,
      query,
      [
        {2, 1},
        {3, Map.get(measurements, :query_time, 0)},
        {4, Map.get(measurements, :queue_time, 0)}
      ],
      {query, 0, 0, 0}
    )

    duration =
      measurements
      |> Map.get(:query_time, 0)
      |> System.convert_time_unit(:native, :millisecond)

    if duration >= 100 do
      :ets.insert(:capacity_slow_queries, {
        {duration, System.unique_integer([:positive])},
        System.monotonic_time(:millisecond),
        query
      })

      if :ets.info(:capacity_slow_queries, :size) > 100,
        do: :ets.delete(:capacity_slow_queries, :ets.first(:capacity_slow_queries))
    end
  end

  # Query timings alone conflate waiting writers with the transaction holding
  # the fence. Track the post-acquisition interval in the checkout's caller;
  # retain only five SQL shapes and never log tenant payloads or parameters.
  defp record_canonical_hold(query, measurements) do
    now = System.monotonic_time(:microsecond)
    elapsed = System.convert_time_unit(measurements[:query_time] || 0, :native, :microsecond)

    cond do
      query in ["begin", "rollback"] ->
        Process.delete(:capacity_canonical_hold)

      query == "commit" ->
        case Process.delete(:capacity_canonical_hold) do
          {started, sql_us, slowest} when now - started >= 100_000 ->
            IO.puts(
              Jason.encode!(%{
                finished_at_ms: System.system_time(:millisecond),
                canonical_hold_ms: (now - started) / 1_000,
                sql_ms: (sql_us + elapsed) / 1_000,
                slowest: slowest
              })
            )

          _ ->
            :ok
        end

      String.contains?(query, "FOR NO KEY UPDATE") and
          String.contains?(query, "FROM \"organizations\"") ->
        # Reentrant acquisitions must not reset the outer transaction clock.
        unless Process.get(:capacity_canonical_hold),
          do: Process.put(:capacity_canonical_hold, {now, 0, []})

      true ->
        case Process.get(:capacity_canonical_hold) do
          {started, sql_us, slowest} ->
            slowest =
              [
                %{
                  query: query,
                  query_ms: elapsed / 1_000,
                  finished_at_ms: System.system_time(:millisecond)
                }
                | slowest
              ]
              |> Enum.sort_by(& &1.query_ms, :desc)
              |> Enum.take(5)

            Process.put(:capacity_canonical_hold, {started, sql_us + elapsed, slowest})

          nil ->
            :ok
        end
    end
  end

  def record_rejection(_event, _measurements, metadata, _config) do
    key = "#{metadata.lane}:#{metadata.reason}"
    :ets.update_counter(__MODULE__, key, {2, 1}, {key, 0})
  end

  defp assert_accepted!(result) do
    unless Enum.all?(result.statuses, fn {status, _} -> status in [200, 202] end),
      do: raise("load phase #{result.name} failed; see status/reconciliation totals")
  end

  defp sample_backlog(samples, next_sample \\ 0) do
    observe_successes(:ets.select(:capacity_receipts, [{{:"$1", :_}, [], [:"$1"]}]))
    now = System.monotonic_time(:millisecond)

    {samples, next_sample} =
      if next_sample == 0 or now >= next_sample do
        {[%{at_ms: System.system_time(:millisecond), organizations: backlog()} | samples],
         now + 1_000}
      else
        {samples, next_sample}
      end

    receive do
      :stop -> Enum.reverse(samples)
    after
      100 -> sample_backlog(samples, next_sample)
    end
  end

  defp backlog do
    organizations = :persistent_term.get({__MODULE__, :organizations})

    rows =
      Repo.all(
        from lane in ReconciliationLane,
          left_join: work in ReconciliationWork,
          on: work.organization_id == lane.organization_id and work.status != "succeeded",
          where: lane.organization_id in ^organizations,
          group_by: [lane.organization_id, lane.pending_units, lane.pending_bytes, work.status],
          select: %{
            organization_id: lane.organization_id,
            pending_units: lane.pending_units,
            pending_bytes: lane.pending_bytes,
            status: work.status,
            count: count(work.id),
            oldest: min(work.inserted_at),
            now: type(fragment("clock_timestamp()"), :utc_datetime_usec)
          }
      )

    rows
    |> Enum.group_by(& &1.organization_id)
    |> Enum.map(fn {org, [first | _] = rows} ->
      %{
        organization_id: org,
        pending_units: first.pending_units,
        pending_bytes: first.pending_bytes,
        outstanding:
          rows
          |> Enum.reject(&(&1.count == 0))
          |> Enum.map(fn row ->
            %{
              status: row.status,
              count: row.count,
              oldest_age_ms: DateTime.diff(row.now, row.oldest, :millisecond)
            }
          end)
      }
    end)
  end

  defp drain(ids, validate? \\ true) do
    started = System.monotonic_time(:millisecond)
    if validate?, do: validate_receipts!(ids)
    await_success(ids, started + @drain_ms)

    times =
      ids
      |> Enum.map(fn id ->
        [{^id, accepted, observed}] = :ets.lookup(:capacity_successes, id)
        DateTime.diff(observed, accepted, :millisecond)
      end)
      |> Enum.sort()

    assert_debits!()

    %{
      accepted_work: length(ids),
      succeeded_work: length(times),
      drain_ms: System.monotonic_time(:millisecond) - started,
      accepted_to_observed_success_p95_ms: percentile(times, 0.95),
      accepted_to_observed_success_p99_ms: percentile(times, 0.99),
      accepted_to_observed_success_max_ms: List.last(times),
      nominal_poll_ms: 100,
      final_backlog: backlog()
    }
  end

  defp percentile([], _fraction), do: nil

  defp percentile(times, fraction),
    do: Enum.at(times, min(trunc(length(times) * fraction), length(times) - 1))

  defp await_success(ids, deadline) do
    observe_successes(ids)

    statuses =
      Repo.all(from work in ReconciliationWork, where: work.id in ^ids, select: work.status)

    cond do
      length(statuses) == length(ids) and Enum.all?(statuses, &(&1 == "succeeded")) ->
        # A turn can commit between the observation query and this status read.
        observe_successes(ids)
        :ok

      "quarantined" in statuses ->
        raise("processing quarantined work: #{inspect(Enum.frequencies(statuses))}")

      System.monotonic_time(:millisecond) >= deadline ->
        raise("processing drain timed out: #{inspect(backlog())}")

      true ->
        Process.sleep(100)
        await_success(ids, deadline)
    end
  end

  # The database clock is sampled only after the succeeded row is visible to
  # another connection. Unlike attempt.completed_at this includes commit and
  # required effects. Poll scheduling/query time makes it an upper bound.
  defp observe_successes(ids) do
    unseen = Enum.reject(ids, &:ets.member(:capacity_successes, &1))

    Repo.all(
      from work in ReconciliationWork,
        where: work.id in ^unseen and work.status == "succeeded",
        select:
          {work.id, work.inserted_at, type(fragment("clock_timestamp()"), :utc_datetime_usec)}
    )
    |> Enum.each(&:ets.insert_new(:capacity_successes, &1))
  end

  defp validate_receipts!(ids) do
    unless length(Enum.uniq(ids)) == length(ids),
      do: raise("reused receipt for fresh submissions")

    rows =
      Repo.all(
        from work in ReconciliationWork,
          join: observation in Observation,
          on:
            observation.id == work.observation_id and observation.source_id == work.source_id and
              observation.organization_id == work.organization_id,
          join: agent in Agent,
          on:
            agent.id == work.installation_agent_id and agent.source_id == work.source_id and
              agent.organization_id == work.organization_id,
          where: work.id in ^ids,
          select:
            {work.id,
             %{
               organization_id: work.organization_id,
               installation_id: agent.installation_id,
               observation_id: observation.id,
               submitted: observation.idempotency_key,
               source_id: observation.source_id,
               position: work.position,
               accepted_at: work.inserted_at
             }}
      )
      |> Map.new()

    for id <- ids do
      [{^id, expected}] = :ets.lookup(:capacity_receipts, id)
      actual = Map.fetch!(rows, id)

      unless Map.delete(actual, :accepted_at) == Map.delete(expected, :accepted_at) and
               DateTime.compare(actual.accepted_at, expected.accepted_at) == :eq,
             do: raise("receipt does not identify submitted obligation")
    end
  end

  # A successful HTTP receipt is insufficient: persisted accounting must equal
  # the unresolved obligations, including when another organization is busy.
  defp assert_debits! do
    organizations = :persistent_term.get({__MODULE__, :organizations})

    # One MVCC snapshot, not separate reads racing the noisy worker's debit.
    accounting =
      Repo.all(
        from lane in ReconciliationLane,
          left_join: work in ReconciliationWork,
          on: work.organization_id == lane.organization_id and work.status != "succeeded",
          where: lane.organization_id in ^organizations,
          group_by: [lane.organization_id, lane.pending_units, lane.pending_bytes],
          select: {
            lane.pending_units,
            lane.pending_bytes,
            fragment("COALESCE(SUM(?), 0)::bigint", work.units),
            fragment("COALESCE(SUM(?), 0)::bigint", work.bytes)
          }
      )

    for {units, bytes, expected_units, expected_bytes} <- accounting do
      unless units == expected_units and bytes == expected_bytes,
        do: raise("pending reservation does not match outstanding work")
    end
  end

  defp assert_resources!(fleet, expected) do
    resources =
      Repo.all(
        from(resource in Renga.Inventory.Resource,
          where: resource.organization_id == ^fleet.organization.id,
          select: resource.id
        )
      )

    interfaces =
      Repo.all(
        from interface in Renga.Inventory.Interface,
          where: interface.organization_id == ^fleet.organization.id,
          group_by: interface.resource_id,
          select: {interface.resource_id, count(interface.id)}
      )
      |> Map.new()

    memory =
      Repo.all(
        from component in Renga.Catalog.ActualComponent,
          where:
            component.organization_id == ^fleet.organization.id and component.kind == "memory" and
              component.status == "present",
          group_by: component.owner_resource_id,
          select: {component.owner_resource_id, count(component.id)}
      )
      |> Map.new()

    unless length(resources) == expected and
             Enum.all?(resources, &(Map.get(interfaces, &1) == 4 and Map.get(memory, &1) == 12)),
           do:
             raise(
               "canonical fixture must have #{expected} hosts, each with four interfaces and twelve DIMMs"
             )

    %{
      hosts: length(resources),
      interfaces: Enum.sum(Map.values(interfaces)),
      memory_components: Enum.sum(Map.values(memory))
    }
  end

  defp processing_neighbor(fleet, quiet, hosts) do
    worker = Renga.Inventory.ReconciliationWorker
    :ok = :sys.suspend(worker)

    noisy =
      try do
        noisy = for {n, id} <- Enum.take(Stream.cycle(hosts), 500), do: observation(fleet, n, id)

        unless Enum.all?(noisy, &(&1.status == 202)),
          do: raise("noisy processing setup was rejected")

        ids = Enum.map(noisy, & &1.work_id)
        validate_receipts!(ids)

        pending =
          Repo.all(
            from work in ReconciliationWork,
              where: work.id in ^ids,
              select: {work.status, work.units, work.bytes}
          )

        unless length(pending) == 500 and
                 Enum.all?(pending, fn {status, units, _bytes} ->
                   status == "pending" and units == 1
                 end),
               do: raise("noisy setup must retain 500 pending host roots before resuming")

        assert_debits!()
        bytes = Enum.sum(Enum.map(pending, &elem(&1, 2)))

        unless ReconciliationWork.pending_units(fleet.organization.id) == 500 and
                 ReconciliationWork.pending_bytes(fleet.organization.id) == bytes,
               do: raise("noisy prefill reservation differs from its 500 roots")

        IO.puts(
          Jason.encode!(%{
            event: "noisy_prefill",
            pending_roots: length(pending),
            units: 500,
            bytes: bytes
          })
        )

        noisy
      after
        :ok = :sys.resume(worker)
      end

    queued = ReconciliationWork.pending_units(fleet.organization.id)
    unless queued > 0, do: raise("no noisy backlog at quiet arrival")

    result =
      phase(
        "processing_noisy_neighbor",
        1..20,
        fn n ->
          id = Ecto.UUID.generate()
          [checkin(quiet, id), observation(quiet, 200_000 + n, id)]
        end,
        1
      )

    assert_accepted!(result)
    identities = for n <- 1..20, do: "capacity-machine-#{200_000 + n}"

    canonical =
      Repo.all(
        from identifier in Renga.Inventory.ResourceIdentifier,
          where:
            identifier.organization_id == ^quiet.organization.id and
              identifier.kind == "machine_id",
          where: identifier.normalized_value in ^identities,
          group_by: identifier.normalized_value,
          select: {identifier.normalized_value, count(identifier.resource_id, :distinct)}
      )
      |> Map.new()

    unless canonical == Map.new(identities, &{&1, 1}),
      do: raise("quiet processing did not preserve exactly one host for every stable identity")

    remaining = ReconciliationWork.pending_units(fleet.organization.id)
    unless remaining > 0, do: raise("control did not overlap quiet completion with noisy backlog")
    noisy_drain = drain(Enum.map(noisy, & &1.work_id))

    Map.merge(result, %{
      noisy_queued_at_arrival: queued,
      noisy_pending_at_quiet_completion: remaining,
      noisy_drain: noisy_drain
    })
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
                size_bytes: 34_359_738_368,
                vendor: "Samsung",
                serial_number:
                  if(System.get_env("LOAD_COMPONENT_SERIALS") != "false", do: "#{n}-#{slot}")
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
    duration = System.monotonic_time(:millisecond) - started

    work_id =
      if path == "/api/v1/observations" and conn.status in [200, 202] do
        %{
          "observation" => %{
            "id" => observation_id,
            "observation_id" => submitted,
            "source_id" => source_id
          },
          "receipt" => %{"id" => id, "position" => position, "accepted_at" => accepted_at}
        } = response

        unless submitted == body.observation_id and is_integer(position) and position > 0,
          do: raise("mismatched observation receipt")

        {:ok, _id} = Ecto.UUID.cast(id)
        {:ok, time, _offset} = DateTime.from_iso8601(accepted_at)

        :ets.insert(
          :capacity_receipts,
          {id,
           %{
             organization_id: fleet.organization.id,
             installation_id: installation,
             observation_id: observation_id,
             submitted: submitted,
             source_id: source_id,
             position: position,
             accepted_at: time
           }}
        )

        id
      end

    rejection_stage =
      case {conn.status, conn.assigns[:current_scope]} do
        {429, nil} -> :credential_lookup
        {429, _scope} -> :limits_or_admission
        _accepted_or_invalid -> nil
      end

    rejected? = conn.status == 429 and path != "/api/v1/agent/jobs/lease"

    if rejected? or (System.get_env("LOAD_PROFILE") == "true" and duration >= 500) do
      # Inspect the real permit holders, not the rejected request's stack.
      # The lease-control rejections are intentional and add no diagnosis.
      permit_holders =
        if rejected? do
          {:monitors, monitors} =
            Process.info(Process.whereis(Renga.IntakeCapacity), :monitors)

          monitors
          |> Enum.uniq()
          |> Enum.flat_map(fn {:process, pid} ->
            case Process.info(pid, [:status, :current_stacktrace]) do
              nil ->
                []

              info ->
                [
                  %{
                    process: inspect(pid),
                    status: info[:status],
                    stack: Exception.format_stacktrace(info[:current_stacktrace])
                  }
                ]
            end
          end)
        else
          []
        end

      pool_metrics =
        Repo
        |> Ecto.Adapter.lookup_meta()
        |> Map.fetch!(:pid)
        |> DBConnection.get_connection_metrics()
        |> Enum.map(&Map.take(&1, [:ready_conn_count, :checkout_queue_length]))

      IO.puts(
        Jason.encode!(%{
          request_at_ms: started,
          finished_at_ms: System.system_time(:millisecond),
          path: path,
          status: conn.status,
          rejection_stage: rejection_stage,
          permit_holders: permit_holders,
          pool_metrics: pool_metrics,
          ms: duration
        })
      )
    end

    %{
      status: conn.status,
      path: path,
      ms: duration,
      work_id: work_id,
      rejection_stage: rejection_stage
    }
  end
end

Renga.CapacityLoad.run()
