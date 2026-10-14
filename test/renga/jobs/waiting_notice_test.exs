defmodule Renga.Jobs.WaitingNoticeTest do
  use Renga.DataCase, async: true

  import Renga.JobsFixtures

  alias Renga.Jobs
  alias Renga.Jobs.Changes

  @collect "inventory.collect@1"

  setup do
    %{organization: organization} = context = job_organization_fixture()
    agent = agent_fixture(organization)
    :ok = Changes.subscribe_waiting(organization.id, agent.id)
    Map.put(context, :agent, agent)
  end

  test "a requested job wakes its agent once the request commits", %{scope: scope, agent: agent} do
    {:ok, _job} = Jobs.create_job(scope, agent.id, @collect, %{})

    agent_id = agent.id
    assert_receive {:jobs_waiting, ^agent_id}
  end

  test "a system job wakes its agent", %{organization: organization, agent: agent} do
    {:ok, _job} = Jobs.create_system_job(organization.id, agent.id, @collect, %{})

    agent_id = agent.id
    assert_receive {:jobs_waiting, ^agent_id}
  end

  test "a rejected request wakes nobody", %{scope: scope} do
    assert {:error, :agent_not_found} =
             Jobs.create_job(scope, Ecto.UUID.generate(), @collect, %{})

    refute_receive {:jobs_waiting, _agent_id}
  end

  test "other agents are not woken", %{organization: organization, scope: scope} do
    other = agent_fixture(organization)
    {:ok, _job} = Jobs.create_job(scope, other.id, @collect, %{})

    refute_receive {:jobs_waiting, _agent_id}
  end

  test "a job re-queued after its lease lapsed wakes its agent again", context do
    %{scope: scope, system_scope: system_scope, agent: agent} = context
    {:ok, _job} = Jobs.create_job(scope, agent.id, @collect, %{})
    agent_id = agent.id
    assert_receive {:jobs_waiting, ^agent_id}

    {:ok, [_leased]} = Jobs.lease_jobs(system_scope, agent, [@collect], 1)
    assert %{lapsed: 1} = Jobs.sweep(DateTime.add(Renga.Time.utc_now_ms(), 61))

    assert_receive {:jobs_waiting, ^agent_id}
  end

  test "a job queued inside a transaction that rolls back wakes nobody", context do
    %{scope: scope, agent: agent} = context

    Changes.after_commit(fn ->
      Repo.transaction(fn ->
        {:ok, _job} = Jobs.create_job(scope, agent.id, @collect, %{})
        Repo.rollback(:abandoned)
      end)
    end)

    refute_receive {:jobs_waiting, _agent_id}
  end
end
