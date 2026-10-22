defmodule Renga.Jobs.ImportedJobsTest do
  use Renga.DataCase, async: true

  import Renga.JobsFixtures

  alias Renga.Jobs
  alias Renga.Jobs.Job

  @collect "inventory.collect@1"

  setup do
    %{organization: organization, scope: owner, system_scope: system_scope} =
      job_organization_fixture()

    agent = agent_fixture(organization)
    %{owner: owner, system_scope: system_scope, agent: agent}
  end

  # Marks a job imported (RFD 20), as an import writes it.
  defp import!(job, changes \\ []) do
    {1, _} =
      Job
      |> where([j], j.id == ^job.id)
      |> Repo.update_all(set: [imported_at: Renga.Time.utc_now_ms()] ++ changes)

    Repo.get!(Job, job.id)
  end

  test "an imported queued job is never leased or waited on", context do
    %{owner: owner, system_scope: system_scope, agent: agent} = context
    {:ok, job} = Jobs.create_job(owner, agent.id, @collect, %{})
    import!(job)

    assert {:ok, []} = Jobs.lease_jobs(system_scope, agent, [@collect], 10)
    refute Jobs.jobs_waiting?(system_scope, agent)
  end

  test "the sweep leaves imported jobs as they were", context do
    %{owner: owner, system_scope: system_scope, agent: agent} = context
    {:ok, first} = Jobs.create_job(owner, agent.id, @collect, %{})
    {:ok, queued} = Jobs.create_job(owner, agent.id, @collect, %{})
    {:ok, [{leased, _token}]} = Jobs.lease_jobs(system_scope, agent, [@collect], 1)
    assert leased.id == first.id
    queued = import!(queued)
    leased = import!(leased)

    Jobs.sweep(DateTime.add(Renga.Time.utc_now_ms(), 365, :day))

    assert Repo.get!(Job, queued.id).state == queued.state
    assert Repo.get!(Job, leased.id).state == "leased"
  end

  test "no one can cancel or otherwise change an imported job", context do
    %{owner: owner, agent: agent} = context
    {:ok, job} = Jobs.create_job(owner, agent.id, @collect, %{})
    job = import!(job)

    assert {:error, :not_found} = Jobs.cancel_job(owner, job.id)

    assert_raise Postgrex.Error, ~r/imported jobs are history/, fn ->
      Repo.update_all(where(Job, [j], j.id == ^job.id), set: [state: "cancelled"])
    end
  end
end
