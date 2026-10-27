# Real connections, durable commits and a large topology; run separately from
# other load controls, only on a disposable renga_test_capacity* database.
defmodule Renga.NeighborGenerationLoad do
  import Ecto.Query
  import Renga.InventoryFixtures
  alias Renga.{Accounts, Inventory, Repo}
  alias Renga.Accounts.Scope
  alias Renga.Topology.{CurrentInterfaceAdjacency, InterfaceNeighborEvidence, NeighborGeneration}

  @interfaces 3_000
  @observed ~U[2099-09-10 12:00:00.000000Z]
  @as_of ~U[2099-09-10 12:00:31Z]

  def run do
    config = Application.fetch_env!(:renga, Repo)

    unless Mix.env() == :test and String.starts_with?(config[:database], "renga_test_capacity"),
      do: raise("use the disposable capacity test database")

    Application.put_env(
      :renga,
      Repo,
      Keyword.merge(config, pool_size: 64, pool: DBConnection.ConnectionPool)
    )

    Mix.Task.run("app.start")
    Logger.configure(level: :error)
    :ets.new(__MODULE__, [:named_table, :public])

    :telemetry.attach(
      "neighbor-generation-timing",
      [:renga, :repo, :query],
      &__MODULE__.query/4,
      nil
    )

    noisy = organization_fixture()
    quiet = organization_fixture()

    try do
      seed(noisy, @interfaces)
      seed(quiet, 4)
      noisy_scope = worker(noisy)
      quiet_scope = worker(quiet)
      before_count = count(noisy)
      started = System.monotonic_time(:millisecond)
      # A different process owns every batch. No caller-local state or Sandbox
      # transaction can accidentally supply progress between invocations.
      {:ok, :building} = restart_step(noisy_scope)
      {:ok, :building} = restart_step(noisy_scope)
      quiet_started = System.monotonic_time(:millisecond)
      advance(quiet_scope, fn -> :ok end)
      quiet_ms = System.monotonic_time(:millisecond) - quiet_started
      unless count(quiet) == 1, do: raise("quiet topology did not publish")

      advance(noisy_scope, fn ->
        unless count(noisy) == before_count, do: raise("partial generation became visible")
      end)

      generation_wall_ms = System.monotonic_time(:millisecond) - started
      unless count(noisy) == div(@interfaces, 4), do: raise("wrong final topology")
      compact_started = System.monotonic_time(:millisecond)
      compact(noisy_scope, count(noisy))
      timings = :ets.tab2list(__MODULE__)

      publication =
        Enum.find(timings, fn {{org, _}, result, _, _, _} ->
          org == noisy.id and result == {:ok, :published}
        end)

      {_, _, publication_wall, publication_transaction, publication_lock} = publication

      IO.puts(
        Jason.encode!(
          %{
            interfaces: @interfaces,
            initial_links: before_count,
            published_links: count(noisy),
            generation_wall_ms: generation_wall_ms,
            quiet_ms: quiet_ms,
            compaction_ms: System.monotonic_time(:millisecond) - compact_started,
            max_batch_wall_ms: timings |> Enum.map(&elem(&1, 2)) |> Enum.max(),
            max_batch_transaction_ms: timings |> Enum.map(&elem(&1, 3)) |> Enum.max(),
            max_org_fence_upper_bound_ms: timings |> Enum.map(&elem(&1, 4)) |> Enum.max(),
            publication_wall_ms: publication_wall,
            publication_transaction_ms: publication_transaction,
            publication_org_fence_upper_bound_ms: publication_lock,
            caller_restarted_every_batch: true,
            partial_publications: 0
          },
          pretty: true
        )
      )
    after
      :telemetry.detach("neighbor-generation-timing")
      Repo.delete!(noisy)
      Repo.delete!(quiet)
    end
  end

  defp seed(organization, size) do
    scope = Accounts.scope_for(organization)
    {:ok, source} = Inventory.create_source(scope, %{name: "neighbor-load", kind: "manual"})

    {:ok, observation} =
      Inventory.create_observation(scope, source.id, %{
        idempotency_key: "neighbor-load",
        observed_at: @observed,
        payload: %{}
      })

    now = Renga.Time.utc_now_ms()

    resources =
      for n <- 1..size,
          do: %{
            id: Ecto.UUID.generate(),
            organization_id: organization.id,
            kind: "server",
            name: "neighbor-#{n}",
            lifecycle_state: "active",
            resource_version: n,
            inserted_at: now,
            updated_at: now
          }

    Repo.insert_all(Inventory.Resource, resources)

    interfaces =
      for {resource, n} <- Enum.with_index(resources, 1) do
        {:ok, mac} =
          Renga.Types.MacAddress.cast(
            "02:00:00:#{hex(div(n, 65536))}:#{hex(rem(div(n, 256), 256))}:#{hex(rem(n, 256))}"
          )

        %{
          id: Ecto.UUID.generate(),
          organization_id: organization.id,
          resource_id: resource.id,
          name: "eth0",
          kind: "ethernet",
          status: "up",
          mac_address: mac,
          inserted_at: now,
          updated_at: now
        }
      end

    Repo.insert_all(Inventory.Interface, interfaces)

    for {[a, b], n} <- interfaces |> Enum.chunk_every(2) |> Enum.with_index() do
      mac = b.mac_address.address |> Tuple.to_list() |> Enum.map_join(":", &hex/1)

      evidence = %{
        id: Ecto.UUID.generate(),
        organization_id: organization.id,
        source_id: source.id,
        observation_id: observation.id,
        local_interface_id: a.id,
        protocol: "lldp",
        remote_chassis_id: mac,
        remote_chassis_id_normalized: mac,
        remote_chassis_id_kind: "mac_address",
        remote_port_id: mac,
        remote_port_id_normalized: mac,
        remote_port_id_kind: "mac_address",
        ttl_seconds: if(rem(n, 2) == 0, do: 30, else: 600),
        observed_at: @observed,
        expires_at: DateTime.add(@observed, if(rem(n, 2) == 0, do: 30, else: 600)),
        metadata: %{},
        inserted_at: now
      }

      Repo.insert_all(InterfaceNeighborEvidence, [evidence])
      [a_id, b_id] = Enum.sort([a.id, b.id])

      Repo.insert_all(CurrentInterfaceAdjacency, [
        %{
          id: Ecto.UUID.generate(),
          organization_id: organization.id,
          interface_a_id: a_id,
          interface_b_id: b_id,
          primary_evidence_id: evidence.id,
          confidence: "reported",
          last_observed_at: @observed,
          metadata: %{"protocols" => ["lldp"]},
          inserted_at: now,
          updated_at: now
        }
      ])
    end
  end

  defp restart_step(scope) do
    Task.async(fn ->
      Process.put(:neighbor_timing, true)
      {microseconds, result} = :timer.tc(fn -> NeighborGeneration.step(scope, @as_of) end)

      :ets.insert(
        __MODULE__,
        {{scope.organization_id, System.unique_integer([:positive])}, result,
         microseconds / 1_000, Process.get(:neighbor_transaction_ms),
         Process.get(:neighbor_lock_ms)}
      )

      result
    end)
    |> Task.await(5_000)
  end

  # Query telemetry brackets the transaction without inserting extra queries.
  # Starting the fence clock before its SELECT includes lock/connection wait,
  # so this is a conservative upper bound, not an exact server lock sample.
  def query(_event, measurements, %{query: query}, _config) do
    if Process.get(:neighbor_timing) do
      now = System.monotonic_time()
      before_query = now - measurements.total_time

      cond do
        query == "begin" ->
          Process.put(:neighbor_transaction_start, before_query)

        String.contains?(query, "organizations") and String.contains?(query, "FOR NO KEY UPDATE") ->
          Process.put(:neighbor_lock_start, before_query)

        query == "commit" ->
          Process.put(
            :neighbor_transaction_ms,
            System.convert_time_unit(
              now - Process.get(:neighbor_transaction_start),
              :native,
              :microsecond
            ) / 1_000
          )

          Process.put(
            :neighbor_lock_ms,
            System.convert_time_unit(
              now - Process.get(:neighbor_lock_start),
              :native,
              :microsecond
            ) / 1_000
          )

        true ->
          :ok
      end
    end
  end

  defp advance(scope, unchanged) do
    Enum.reduce_while(1..20_000, nil, fn _, _ ->
      case restart_step(scope) do
        {:ok, :published} ->
          {:halt, :published}

        {:ok, :building} ->
          unchanged.()
          {:cont, nil}

        result ->
          raise("generation failed: #{inspect(result)}")
      end
    end)
    |> then(fn result ->
      unless result == :published, do: raise("generation made no progress")
    end)
  end

  defp compact(scope, expected) do
    Enum.reduce_while(1..20_000, nil, fn _, _ ->
      result = restart_step(scope)

      unless count(%{id: scope.organization_id}) == expected,
        do: raise("compaction changed topology")

      if result == {:ok, :cleaned}, do: {:halt, :cleaned}, else: {:cont, nil}
    end)
    |> then(fn result -> unless result == :cleaned, do: raise("compaction made no progress") end)
  end

  defp count(org),
    do:
      Repo.aggregate(
        from(a in CurrentInterfaceAdjacency, where: a.organization_id == ^org.id),
        :count
      )

  defp worker(org), do: %Scope{organization_id: org.id, roles: ["topology_reconciler"]}
  defp hex(n), do: Integer.to_string(n, 16) |> String.downcase() |> String.pad_leading(2, "0")
end

Renga.NeighborGenerationLoad.run()
