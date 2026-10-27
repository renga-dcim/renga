# Run separately from fleet load, against the disposable capacity database.
# The real ConnectionPool matters: killing a borrowed SQL Sandbox transaction
# destroys its test owner's connection instead of exercising production recovery.
defmodule Renga.ExportCapacityLoad do
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
            forced_owner_death_cancels_snapshot: true
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
end

Renga.ExportCapacityLoad.run()
