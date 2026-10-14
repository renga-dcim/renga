defmodule Renga.Jobs.SweepTest do
  use Renga.DataCase, async: true

  import Renga.JobsFixtures

  alias Renga.Jobs
  alias Renga.Jobs.Job

  @collect "inventory.collect@1"
  @restart "test.restart@1"

  setup do
    %{organization: organization} = context = job_organization_fixture()

    organization
    |> Ecto.Changeset.change(
      settings: %{"jobs" => %{"allowed_capabilities" => [@collect, @restart]}}
    )
    |> Repo.update!()

    Map.put(context, :agent, agent_fixture(organization, [@collect, @restart]))
  end

  defp queue(%{organization: organization, agent: agent}, key, opts \\ []) do
    params = if key == @restart, do: %{"service" => "sshd"}, else: %{}
    {:ok, job} = Jobs.create_system_job(organization.id, agent.id, key, params, opts)
    job
  end

  defp lease(%{system_scope: scope, agent: agent}, key) do
    {:ok, [{job, token}]} = Jobs.lease_jobs(scope, agent, [key], 1)
    {job, token}
  end

  defp start(context, key) do
    {job, token} = lease(context, key)
    {:ok, job} = Jobs.report(context.system_scope, context.agent, job.id, token, "started", %{})
    {job, token}
  end

  defp later, do: DateTime.add(Renga.Time.utc_now_ms(), 61)

  defp types(scope, job), do: scope |> Jobs.list_events(job) |> Enum.map(& &1.type)

  test "re-queues a job whose lease lapsed before it started", context do
    queue(context, @restart)
    {job, token} = lease(context, @restart)

    assert %{lapsed: 1} = Jobs.sweep(later())

    requeued = Repo.reload!(job)
    assert requeued.state == "queued"
    refute requeued.lease_token_hash
    assert types(context.scope, job) == ["created", "leased", "lease_lost"]

    assert {:error, :lease_not_held} =
             Jobs.report(context.system_scope, context.agent, job.id, token, "started", %{})
  end

  test "re-queues a started idempotent job", context do
    queue(context, @collect)
    {job, _token} = start(context, @collect)

    Jobs.sweep(later())

    requeued = Repo.reload!(job)
    assert requeued.state == "queued"
    refute requeued.started_at

    {again, _token} = lease(context, @collect)
    assert again.attempts == 2
  end

  test "marks a started imperative job uncertain instead of running it again", context do
    queue(context, @restart)
    {job, _token} = start(context, @restart)

    Jobs.sweep(later())

    uncertain = Repo.reload!(job)
    assert uncertain.state == "uncertain"
    refute uncertain.finished_at

    assert types(context.scope, job) == [
             "created",
             "leased",
             "started",
             "lease_lost",
             "uncertain"
           ]

    assert {:ok, []} = Jobs.lease_jobs(context.system_scope, context.agent, [@restart], 1)
  end

  test "expires a job out of attempts", context do
    queue(context, @collect, max_attempts: 1)
    {job, _token} = lease(context, @collect)

    Jobs.sweep(later())

    expired = Repo.reload!(job)
    assert expired.state == "expired"
    assert expired.finished_at
    assert types(context.scope, job) == ["created", "leased", "lease_lost", "expired"]
  end

  test "expires a job whose deadline passed while leased", context do
    queue(context, @collect, not_after: DateTime.add(Renga.Time.utc_now_ms(), 30))
    {job, _token} = lease(context, @collect)

    Jobs.sweep(later())

    assert Repo.reload!(job).state == "expired"
  end

  test "honours a requested cancellation over a retry", context do
    queue(context, @collect)
    {job, _token} = start(context, @collect)
    {:ok, _job} = Jobs.cancel_job(context.scope, job.id)

    Jobs.sweep(later())

    assert Repo.reload!(job).state == "cancelled"
  end

  test "expires queued jobs past their deadline", context do
    job = queue(context, @collect, not_after: DateTime.add(Renga.Time.utc_now_ms(), 30))

    assert %{expired: 0} = Jobs.sweep()
    assert %{expired: 1} = Jobs.sweep(later())

    assert Repo.reload!(job).state == "expired"
    assert types(context.scope, job) == ["created", "expired"]
  end

  test "leaves live leases and finished jobs alone", context do
    queue(context, @collect)
    {job, _token} = start(context, @collect)

    assert %{lapsed: 0, expired: 0} = Jobs.sweep()
    assert Repo.reload!(job).state == "running"
  end

  test "is idempotent", context do
    queue(context, @restart)
    {job, _token} = start(context, @restart)

    Jobs.sweep(later())
    assert %{lapsed: 0} = Jobs.sweep(later())
    assert length(Jobs.list_events(context.scope, job)) == 5
  end

  describe "resolving uncertain jobs" do
    setup context do
      queue(context, @restart)
      {job, _token} = start(context, @restart)
      Jobs.sweep(later())
      %{job: job}
    end

    test "an owner records the outcome with a note", %{scope: scope, job: job} do
      assert {:ok, resolved} = Jobs.resolve_job(scope, job.id, "succeeded", "sshd was up")
      assert resolved.state == "succeeded"
      assert resolved.finished_at

      resolved_event = scope |> Jobs.list_events(job) |> List.last()
      assert resolved_event.type == "resolved"
      assert resolved_event.actor_id == scope.user.id
      assert resolved_event.payload == %{"outcome" => "succeeded", "note" => "sshd was up"}

      assert {:error, :not_uncertain} = Jobs.resolve_job(scope, job.id, "failed")
    end

    test "members cannot resolve", %{organization: organization, job: job} do
      assert {:error, :forbidden} =
               Jobs.resolve_job(member_scope(organization, "member"), job.id, "failed")
    end

    test "reconciliation resolves as the system", %{
      organization: organization,
      scope: scope,
      job: job
    } do
      assert {:ok, %Job{state: "failed", failure_reason: "resolved_failed"}} =
               Jobs.reconcile_job(organization.id, job.id, "failed", %{"observed" => "stopped"})

      resolved_event = scope |> Jobs.list_events(job) |> List.last()
      assert resolved_event.actor_type == "system"
      assert resolved_event.payload == %{"outcome" => "failed", "observed" => "stopped"}
    end
  end

  test "the worker sweeps on its interval" do
    parent = self()

    start_supervised!(
      {Renga.Jobs.Sweeper, name: nil, interval: 10, sweep: fn -> send(parent, :swept) end}
    )

    assert_receive :swept
    assert_receive :swept
  end
end
