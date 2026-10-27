# Real PostgreSQL scheduling control. Run separately from the intake load:
# MIX_ENV=test MIX_TEST_PARTITION=_capacity mix run --no-start scripts/load-lease-sweep.exs
defmodule Renga.LeaseSweepLoad do
  import Ecto.Query
  import Renga.InventoryFixtures
  import Renga.JobsFixtures
  alias Renga.{Accounts, Jobs, Repo}
  alias Renga.Jobs.Job

  @organizations 100
  @jobs_per_organization 25
  @handling_budget_ms 30_000

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
    :ets.new(__MODULE__, [:named_table, :public])

    organizations =
      for _ <- 1..@organizations do
        organization = organization_fixture()
        agent = agent_fixture(organization, ["inventory.collect@1"])

        for _ <- 1..@jobs_per_organization do
          {:ok, _job} =
            Jobs.create_system_job(organization.id, agent.id, "inventory.collect@1", %{})
        end

        {:ok, leased} =
          Jobs.lease_jobs(Accounts.scope_for(organization), agent, ["inventory.collect@1"], 25)

        unless length(leased) == @jobs_per_organization,
          do: raise("fixture did not lease all jobs")

        organization
      end

    ids = Enum.map(organizations, & &1.id)
    [noisy | quiet] = Enum.sort(ids)
    parent = self()

    # Model a noisy organization holding its domain lock throughout the
    # rotation, and retention occupying the entire general background lane.
    # Neither is allowed to take the job-expiry reserve away from quiet orgs.
    blocker =
      Task.async(fn ->
        Repo.transaction(fn ->
          Repo.query!("SELECT id FROM organizations WHERE id = $1 FOR UPDATE", [
            Ecto.UUID.dump!(noisy)
          ])

          send(parent, :noisy_locked)

          receive do
            :release -> :ok
          after
            60_000 -> raise("lease-sweep control exceeded its wall budget")
          end
        end)
      end)

    assert_noisy_lock!()
    {:ok, reserve} = Renga.IntakeCapacity.acquire(:background, 1)
    expired_at = DateTime.add(Renga.Time.utc_now_ms(), -1, :second)

    from(job in Job, where: job.organization_id in ^ids)
    |> Repo.update_all(set: [lease_expires_at: expired_at])

    :telemetry.attach(
      "capacity-lease-sweep",
      [:renga, :background, :batch, :start],
      &__MODULE__.batch_started/4,
      nil
    )

    started = System.monotonic_time(:millisecond)

    try do
      rounds = rotate_until_served(quiet, started, 0)

      delays =
        Enum.map(quiet, fn id ->
          [{^id, at}] = :ets.lookup(__MODULE__, id)
          at - started
        end)

      remaining =
        Repo.aggregate(
          from(job in Job,
            where: job.organization_id in ^quiet and job.state in ["leased", "running"]
          ),
          :count
        )

      noisy_remaining =
        Repo.aggregate(
          from(job in Job,
            where: job.organization_id == ^noisy and job.state == "leased"
          ),
          :count
        )

      result = %{
        ready_organizations: @organizations,
        leased_jobs_per_organization: @jobs_per_organization,
        quiet_organizations_served: length(delays),
        maximum_ready_delay_ms: Enum.max(delays),
        elapsed_ms: System.monotonic_time(:millisecond) - started,
        handling_budget_ms: @handling_budget_ms,
        rounds: rounds,
        quiet_leases_remaining: remaining,
        noisy_leases_remaining: noisy_remaining,
        retention_lane_saturated: true
      }

      IO.puts(Jason.encode!(result, pretty: true))

      unless Enum.max(delays) + 250 < @handling_budget_ms and remaining == 0 and
               noisy_remaining == @jobs_per_organization,
             do: raise("ready-organization lease handling gate failed")
    after
      :telemetry.detach("capacity-lease-sweep")
      Renga.IntakeCapacity.release(reserve)
      send(blocker.pid, :release)
      Task.await(blocker, 5_000)
      # Only this invocation's disposable fixture, not another run's data.
      Enum.each(organizations, &Repo.delete!/1)
    end
  end

  def batch_started(_event, _measurements, %{worker: "job_sweep", organization_id: id}, _config),
    do: :ets.insert_new(__MODULE__, {id, System.monotonic_time(:millisecond)})

  def batch_started(_event, _measurements, _metadata, _config), do: :ok

  defp rotate_until_served(quiet, started, rounds) do
    Jobs.sweep()

    cond do
      Enum.all?(quiet, &:ets.member(__MODULE__, &1)) ->
        rounds + 1

      System.monotonic_time(:millisecond) - started >= @handling_budget_ms ->
        raise("not all ready organizations received a batch inside the handling budget")

      true ->
        # Same cadence as Jobs.Sweeper: one second after the rotation ends.
        Process.sleep(1_000)
        rotate_until_served(quiet, started, rounds + 1)
    end
  end

  defp assert_noisy_lock! do
    receive do
      :noisy_locked -> :ok
    after
      5_000 -> raise("noisy organization did not acquire its control lock")
    end
  end
end

Renga.LeaseSweepLoad.run()
