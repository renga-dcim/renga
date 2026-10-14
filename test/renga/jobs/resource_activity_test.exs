defmodule Renga.Jobs.ResourceActivityTest do
  use Renga.DataCase, async: true

  import Renga.JobsFixtures

  alias Renga.Inventory
  alias Renga.Inventory.ChangeEvent
  alias Renga.Jobs
  alias Renga.Jobs.Changes

  @collect "inventory.collect@1"

  setup do
    %{organization: organization} = context = job_organization_fixture()
    agent = agent_fixture(organization)

    context
    |> Map.put(:agent, agent)
    |> Map.put(:resource, reported_resource_fixture(organization, agent))
  end

  defp activity(resource) do
    ChangeEvent
    |> where([event], event.resource_id == ^resource.id)
    |> where([event], event.kind in ["job_requested", "job_outcome"])
    |> order_by([event], asc: event.inserted_at, asc: event.kind)
    |> Repo.all()
  end

  defp run(context, type, payload) do
    {:ok, [{job, token}]} = Jobs.lease_jobs(context.system_scope, context.agent, [@collect], 1)
    {:ok, _} = Jobs.report(context.system_scope, context.agent, job.id, token, "started", %{})
    Jobs.report(context.system_scope, context.agent, job.id, token, type, payload)
  end

  test "a job requested from a resource records its request and outcome there", context do
    %{scope: scope, agent: agent, resource: resource} = context

    assert {:ok, job} = Jobs.create_job(scope, agent.id, @collect, %{}, resource_id: resource.id)
    assert job.resource_id == resource.id

    assert [requested] = activity(resource)
    assert requested.kind == "job_requested"
    assert requested.actor_user_id == scope.user.id
    assert requested.field == @collect

    assert requested.metadata == %{
             "job_id" => job.id,
             "title" => "Collect inventory",
             "noun" => "Inventory collection",
             "state" => "queued"
           }

    observation_id = Ecto.UUID.generate()
    {:ok, _} = run(context, "succeeded", %{"result" => %{"observation_id" => observation_id}})

    assert [_requested, outcome] = activity(resource)
    assert outcome.kind == "job_outcome"
    assert outcome.actor_user_id == nil
    assert outcome.metadata["state"] == "succeeded"
    assert outcome.metadata["observation_id"] == observation_id

    assert [%{kind: "job_outcome"}, %{kind: "job_requested"}] =
             scope |> Inventory.list_activity() |> Enum.filter(&(&1.resource_id == resource.id))

    assert RengaWeb.ChangeDescription.describe(outcome) == "Inventory collection succeeded"
    assert RengaWeb.ChangeDescription.describe(requested) == "Inventory collection requested"
  end

  test "progress stays in the job's history and failures carry their reason", context do
    %{scope: scope, agent: agent, resource: resource} = context
    {:ok, _job} = Jobs.create_job(scope, agent.id, @collect, %{}, resource_id: resource.id)

    {:ok, _} = run(context, "failed", %{"reason" => "collector exited 1"})

    assert [_requested, outcome] = activity(resource)
    assert outcome.metadata["state"] == "failed"
    assert outcome.metadata["failure_reason"] == "collector exited 1"
  end

  test "a person who cancels a queued job is the outcome's actor", context do
    %{scope: scope, agent: agent, resource: resource} = context
    {:ok, job} = Jobs.create_job(scope, agent.id, @collect, %{}, resource_id: resource.id)

    {:ok, _} = Jobs.cancel_job(scope, job.id)

    assert [_requested, outcome] = activity(resource)
    assert outcome.metadata["state"] == "cancelled"
    assert outcome.actor_user_id == scope.user.id
  end

  test "jobs without a resource record no resource activity", context do
    {:ok, _job} = Jobs.create_job(context.scope, context.agent.id, @collect, %{})
    assert activity(context.resource) == []
  end

  test "refuses a resource the agent does not report on", context do
    %{organization: organization, scope: scope, agent: agent} = context
    other_agent = agent_fixture(organization)
    unrelated = reported_resource_fixture(organization, other_agent, "compute-02")

    assert {:error, :agent_not_for_resource} =
             Jobs.create_job(scope, agent.id, @collect, %{}, resource_id: unrelated.id)

    assert {:error, :resource_not_found} =
             Jobs.create_job(scope, agent.id, @collect, %{}, resource_id: Ecto.UUID.generate())

    other = job_organization_fixture()
    foreign = reported_resource_fixture(other.organization, agent_fixture(other.organization))

    assert {:error, :resource_not_found} =
             Jobs.create_job(scope, agent.id, @collect, %{}, resource_id: foreign.id)
  end

  test "lists a resource's agents and its latest job", context do
    %{scope: scope, agent: agent, resource: resource} = context

    assert [listed] = Jobs.list_resource_agents(scope, resource.id)
    assert listed.id == agent.id
    assert Jobs.latest_resource_job(scope, resource.id) == nil

    {:ok, job} = Jobs.create_job(scope, agent.id, @collect, %{}, resource_id: resource.id)

    latest = Jobs.latest_resource_job(scope, resource.id)
    assert latest.id == job.id
    assert latest.agent.id == agent.id
    assert latest.requested_by_user.id == scope.user.id
  end

  test "groups jobs by state for the Jobs list", context do
    %{scope: scope, agent: agent} = context
    {:ok, queued} = Jobs.create_job(scope, agent.id, @collect, %{})
    {:ok, cancelled} = Jobs.create_job(scope, agent.id, @collect, %{})
    {:ok, _} = Jobs.cancel_job(scope, cancelled.id)

    assert [%{id: id}] = Jobs.list_jobs(scope, group: "open")
    assert id == queued.id
    assert [%{id: id}] = Jobs.list_jobs(scope, group: "finished")
    assert id == cancelled.id
    assert Jobs.list_jobs(scope, group: "needs_review") == []

    assert Jobs.count_jobs_by_group(scope) == %{"open" => 1, "finished" => 1, "needs_review" => 0}
  end

  test "announces job changes after they commit", context do
    %{scope: scope, agent: agent} = context
    organization_id = scope.organization_id
    :ok = Changes.subscribe(scope)

    {:ok, job} = Jobs.create_job(scope, agent.id, @collect, %{})
    assert_receive {:jobs_changed, ^organization_id}

    {:ok, []} = Jobs.lease_jobs(context.system_scope, agent, ["other.thing@1"], 1)
    refute_receive {:jobs_changed, _}

    {:ok, _} = Jobs.cancel_job(scope, job.id)
    assert_receive {:jobs_changed, ^organization_id}
  end

  test "does not announce a job change rolled back by an outer transaction", context do
    %{scope: scope, agent: agent} = context
    organization_id = scope.organization_id
    :ok = Changes.subscribe(scope)

    assert {:error, :outer_rollback} =
             Changes.after_commit(fn ->
               Repo.transaction(fn ->
                 {:ok, _job} = Jobs.create_job(scope, agent.id, @collect, %{})
                 Repo.rollback(:outer_rollback)
               end)
             end)

    refute_receive {:jobs_changed, ^organization_id}
    assert Jobs.list_jobs(scope) == []
  end
end
