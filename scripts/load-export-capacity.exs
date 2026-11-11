# Run separately from fleet load, against the disposable capacity database.
# The real ConnectionPool matters: killing a borrowed SQL Sandbox transaction
# destroys its test owner's connection instead of exercising production recovery.
defmodule Renga.ExportCapacityLoad do
  import Ecto.Query
  import Renga.InventoryFixtures
  alias Renga.{Repo, Transfers}
  alias Renga.Transfers.OrganizationExport

  def run do
    config = Application.fetch_env!(:renga, Repo)

    unless Mix.env() == :test and
             String.starts_with?(config[:database], "renga_test_capacity"),
           do: raise("use the disposable capacity test database")

    Application.put_env(
      :renga,
      Repo,
      Keyword.merge(config, pool_size: 64, pool: DBConnection.ConnectionPool)
    )

    Application.put_env(
      :renga,
      RengaWeb.Endpoint,
      Keyword.put(Application.fetch_env!(:renga, RengaWeb.Endpoint), :server, false)
    )

    Mix.Task.run("app.start")
    Logger.configure(level: :error)
    noisy = organization_fixture()
    quiet = organization_fixture()
    dir = Path.join(System.tmp_dir!(), "renga-capacity-export-#{Ecto.UUID.generate()}")
    File.mkdir!(dir)
    parent = self()

    try do
      export = Repo.insert!(%OrganizationExport{organization_id: noisy.id, status: "running"})
      neighbor = Repo.insert!(%OrganizationExport{organization_id: quiet.id, status: "running"})
      {:ok, reserve} = Renga.IntakeCapacity.acquire(:export_background, 1)
      unless Transfers.generate_queued() == [], do: raise("export reserve was bypassed")
      Renga.IntakeCapacity.release(reserve)

      started = System.monotonic_time(:millisecond)

      :ok =
        Transfers.run(export.id, fn -> "https://renga.test/settings/export" end,
          budget_ms: 500,
          tmp_dir: dir,
          after_record_type: fn _type ->
            send(parent, {:snapshot_started, self()})
            Process.sleep(:infinity)
          end
        )

      elapsed = System.monotonic_time(:millisecond) - started

      snapshot =
        receive do
          {:snapshot_started, pid} -> pid
        after
          1_000 -> raise("deadline did not exercise a running database snapshot")
        end

      unless not Process.alive?(snapshot) and Repo.reload!(export).status == "failed" and
               File.ls!(dir) == [] and elapsed < 2_000,
             do: raise("snapshot timeout did not cancel and clean up within its budget")

      %{rows: [[0]]} =
        Repo.query!(
          "SELECT count(*) FROM organization_export_chunks WHERE export_id = $1",
          [Ecto.UUID.dump!(export.id)]
        )

      {:ok, general} = Renga.IntakeCapacity.acquire(:background, 1)

      try do
        Transfers.generate_queued()
      after
        Renga.IntakeCapacity.release(general)
      end

      unless Repo.reload!(neighbor).status == "ready", do: raise("quiet export did not progress")

      interrupted =
        Repo.insert!(%OrganizationExport{organization_id: noisy.id, status: "running"})

      owner =
        Task.Supervisor.async_nolink(Renga.Background.Tasks, fn ->
          Transfers.run(interrupted.id, fn -> "https://renga.test/settings/export" end,
            tmp_dir: dir,
            after_record_type: fn _type ->
              send(parent, {:interrupted_snapshot, self()})
              Process.sleep(:infinity)
            end
          )
        end)

      child =
        receive do
          {:interrupted_snapshot, pid} -> pid
        after
          2_000 -> raise("owner-death control did not start a snapshot")
        end

      monitor = Process.monitor(child)
      Process.exit(owner.pid, :kill)
      {:exit, :killed} = Task.yield(owner, 1_000)

      receive do
        {:DOWN, ^monitor, :process, ^child, _reason} -> :ok
      after
        1_000 -> raise("worker death left its snapshot running")
      end

      # Exercise both supervising levels. Replacement attempts begin at the
      # kill, not after observing snapshot death, to expose an early release.
      for killed_owner <- [:scheduler, :coordinator] do
        scheduled =
          Repo.insert!(%OrganizationExport{organization_id: quiet.id, status: "running"})

        snapshot_lock = :erlang.phash2(scheduled.id)

        ready =
          from e in OrganizationExport,
            where: e.id == ^scheduled.id,
            select: %{organization_id: e.organization_id}

        scheduler =
          Task.Supervisor.async_nolink(Renga.Background.Tasks, fn ->
            Renga.Background.run(
              "export_generation",
              ready,
              fn _id ->
                send(parent, {:scheduled_batch, hd(Process.get(:"$callers"))})

                Transfers.run(scheduled.id, fn -> "https://renga.test/settings/export" end,
                  tmp_dir: dir,
                  after_record_type: fn _type ->
                    Repo.query!("SELECT pg_advisory_xact_lock(21, $1)", [snapshot_lock])
                    send(parent, {:scheduled_snapshot, self()})
                    Process.sleep(:infinity)
                  end
                )
              end,
              budget_ms: 5_000,
              batch_timeout_ms: 5_000
            )
          end)

        coordinator =
          receive do
            {:scheduled_batch, pid} -> pid
          after
            2_000 -> raise("scheduled batch did not start")
          end

        scheduled_child =
          receive do
            {:scheduled_snapshot, pid} -> pid
          after
            2_000 -> raise("scheduler-death control did not start a snapshot")
          end

        :full = Renga.IntakeCapacity.acquire(:export_background, 1)
        scheduled_monitor = Process.monitor(scheduled_child)
        Process.exit(if(killed_owner == :scheduler, do: scheduler.pid, else: coordinator), :kill)

        [{:ok, :replacement}] =
          Enum.reduce_while(1..100, nil, fn _, _ ->
            case Renga.Background.run("export_generation", ready, fn _ ->
                   if Process.alive?(scheduled_child),
                     do: raise("replacement overlaps orphan snapshot")

                   %{rows: [[true]]} =
                     Repo.query!("SELECT pg_try_advisory_xact_lock(21, $1)", [snapshot_lock])

                   :replacement
                 end) do
              [] ->
                Process.sleep(10)
                {:cont, nil}

              result ->
                {:halt, result}
            end
          end)

        {:exit, _reason} = Task.yield(scheduler, 1_000)

        receive do
          {:DOWN, ^scheduled_monitor, :process, ^scheduled_child, _reason} -> :ok
        after
          1_000 -> raise("#{killed_owner} death left its snapshot running")
        end

        %{rows: [[0]]} =
          Repo.query!(
            "SELECT count(*) FROM organization_export_chunks WHERE export_id = $1",
            [Ecto.UUID.dump!(scheduled.id)]
          )

        Repo.delete!(scheduled)
      end

      cursor_elapsed =
        blocked_cursor(
          from e in OrganizationExport,
            where: e.id == ^neighbor.id,
            select: %{organization_id: e.organization_id}
        )

      IO.puts(
        Jason.encode!(
          %{
            snapshot_budget_ms: 500,
            cancellation_elapsed_ms: elapsed,
            snapshot_cancelled: true,
            partial_chunks: 0,
            deadline_scratch_files_remaining: 0,
            export_reserve_enforced: true,
            quiet_export_ready_with_general_lane_saturated: true,
            forced_owner_death_cancels_snapshot: true,
            scheduler_death_cancels_snapshot_before_replacement: true,
            coordinator_death_cancels_snapshot_before_replacement: true,
            snapshot_transaction_lock_released_before_replacement: true,
            blocked_cursor_budget_ms: 50,
            blocked_cursor_cancellation_elapsed_ms: cursor_elapsed,
            no_batch_after_cursor_deadline: true
          },
          pretty: true
        )
      )
    after
      Repo.delete!(noisy)
      Repo.delete!(quiet)
      File.rm_rf!(dir)
    end
  end

  defp blocked_cursor(ready) do
    parent = self()
    worker = "blocked-#{Ecto.UUID.generate()}"
    Repo.query!("INSERT INTO background_cursors(worker) VALUES ($1)", [worker])

    holder =
      Task.async(fn ->
        Repo.transaction(fn ->
          Repo.query!("SELECT 1 FROM background_cursors WHERE worker = $1 FOR UPDATE", [worker])
          send(parent, :cursor_locked)
          receive do: (:release -> :ok)
        end)
      end)

    receive do
      :cursor_locked -> :ok
    after
      1_000 -> raise("cursor holder did not start")
    end

    try do
      started = System.monotonic_time(:millisecond)

      [] =
        Renga.Background.run(worker, ready, fn _ -> send(parent, :late_batch) end, budget_ms: 50)

      elapsed = System.monotonic_time(:millisecond) - started

      if elapsed >= 175,
        do: raise("cursor selection escaped its wall budget plus 100ms cancellation grace")

      receive do
        :late_batch -> raise("batch started after cursor-selection deadline")
      after
        100 -> :ok
      end

      {:ok, permit} = Renga.IntakeCapacity.acquire(:background, 1)
      Renga.IntakeCapacity.release(permit)
      elapsed
    after
      send(holder.pid, :release)
      Task.await(holder)
      Repo.query!("DELETE FROM background_cursors WHERE worker = $1", [worker])
    end
  end
end

Renga.ExportCapacityLoad.run()
