defmodule Renga.JobsTest do
  use Renga.DataCase, async: true

  import Renga.JobsFixtures

  alias Renga.Accounts
  alias Renga.Jobs
  alias Renga.Jobs.Job

  @collect "inventory.collect@1"

  setup do
    %{organization: organization} = context = job_organization_fixture()
    Map.put(context, :agent, agent_fixture(organization))
  end

  defp event_types(scope, job), do: scope |> Jobs.list_events(job) |> Enum.map(& &1.type)

  defp lease_one(system_scope, agent, keys \\ [@collect]) do
    {:ok, [{job, token}]} = Jobs.lease_jobs(system_scope, agent, keys, 1)
    {job, token}
  end

  defp allow(organization, keys) do
    organization
    |> Ecto.Changeset.change(settings: %{"jobs" => %{"allowed_capabilities" => keys}})
    |> Repo.update!()
  end

  describe "create_job/5" do
    test "queues the job with its creation event", %{scope: scope, agent: agent} do
      assert {:ok, %Job{} = job} = Jobs.create_job(scope, agent.id, @collect, %{})

      assert job.state == "queued"
      assert job.agent_id == agent.id
      assert job.capability == "inventory.collect"
      assert job.capability_version == 1
      assert job.risk_class == "observe"
      assert job.retry_class == "idempotent"
      assert job.requested_by_type == "user"
      assert job.requested_by_user_id == scope.user.id
      assert job.output_limit_bytes == 64 * 1024
      assert job.last_sequence == 1

      assert [created] = Jobs.list_events(scope, job)
      assert created.type == "created"
      assert created.actor_type == "user"
      assert created.actor_id == scope.user.id
      assert created.payload == %{"capability" => @collect}
    end

    test "lets owners and admins request observe jobs, and nobody else", %{
      organization: organization,
      system_scope: system_scope,
      agent: agent
    } do
      assert {:ok, _job} =
               Jobs.create_job(member_scope(organization, "admin"), agent.id, @collect, %{})

      for role <- ["member", "viewer"] do
        assert {:error, :forbidden} =
                 Jobs.create_job(member_scope(organization, role), agent.id, @collect, %{})
      end

      assert {:error, :forbidden} = Jobs.create_job(system_scope, agent.id, @collect, %{})
    end

    test "refuses operate capabilities until grants exist", %{
      organization: organization,
      scope: scope
    } do
      allow(organization, ["test.restart@1"])
      agent = agent_fixture(organization, ["test.restart@1"])

      assert {:error, :forbidden} =
               Jobs.create_job(scope, agent.id, "test.restart@1", %{"service" => "sshd"})
    end

    test "requires the organization to allow the capability", %{
      organization: organization,
      scope: scope,
      agent: agent
    } do
      allow(organization, [])
      assert {:error, :capability_not_allowed} = Jobs.create_job(scope, agent.id, @collect, %{})
    end

    test "requires an active agent advertising the capability", %{
      organization: organization,
      scope: scope,
      agent: agent
    } do
      unadvertised = agent_fixture(organization, ["host.inventory"])

      assert {:error, :capability_not_advertised} =
               Jobs.create_job(scope, unadvertised.id, @collect, %{})

      agent |> Ecto.Changeset.change(status: "disabled") |> Repo.update!()
      assert {:error, :agent_disabled} = Jobs.create_job(scope, agent.id, @collect, %{})

      assert {:error, :agent_not_found} =
               Jobs.create_job(scope, Ecto.UUID.generate(), @collect, %{})

      assert {:error, :agent_not_found} = Jobs.create_job(scope, "not-a-uuid", @collect, %{})
    end

    test "never targets another organization's agent", %{scope: scope} do
      %{organization: other} = job_organization_fixture()
      foreign = agent_fixture(other)

      assert {:error, :agent_not_found} = Jobs.create_job(scope, foreign.id, @collect, %{})
    end

    test "validates parameters before storing anything", %{scope: scope, agent: agent} do
      assert {:error, %Ecto.Changeset{}} =
               Jobs.create_job(scope, agent.id, @collect, %{"command" => "id"})

      assert Jobs.list_jobs(scope) == []
    end

    test "rejects unknown capabilities", %{scope: scope, agent: agent} do
      assert {:error, :unknown_capability} =
               Jobs.create_job(scope, agent.id, "inventory.collect@9", %{})
    end

    test "returns the same job for a retried request", %{scope: scope, agent: agent} do
      assert {:ok, job} = Jobs.create_job(scope, agent.id, @collect, %{}, idempotency_key: "k1")
      assert {:ok, again} = Jobs.create_job(scope, agent.id, @collect, %{}, idempotency_key: "k1")

      assert again.id == job.id
      assert length(Jobs.list_jobs(scope)) == 1
    end

    test "rejects an idempotency key reused for a different request", %{
      organization: organization,
      scope: scope,
      agent: agent
    } do
      other_agent = agent_fixture(organization)
      assert {:ok, _job} = Jobs.create_job(scope, agent.id, @collect, %{}, idempotency_key: "k1")

      assert {:error, :idempotency_conflict} =
               Jobs.create_job(scope, other_agent.id, @collect, %{}, idempotency_key: "k1")
    end

    test "bounds the lease deadline", %{scope: scope, agent: agent} do
      now = Renga.Time.utc_now_ms()

      assert {:ok, job} =
               Jobs.create_job(scope, agent.id, @collect, %{}, not_after: DateTime.add(now, 60))

      assert DateTime.diff(job.not_after, now) == 60

      for not_after <- [DateTime.add(now, -1), DateTime.add(now, 8 * 24 * 3600), "tomorrow"] do
        assert {:error, :invalid_deadline} =
                 Jobs.create_job(scope, agent.id, @collect, %{}, not_after: not_after)
      end
    end

    test "system jobs skip role checks but not organization checks", %{
      organization: organization
    } do
      allow(organization, ["test.restart@1"])
      agent = agent_fixture(organization, ["test.restart@1"])

      assert {:ok, job} =
               Jobs.create_system_job(organization.id, agent.id, "test.restart@1", %{
                 "service" => "sshd"
               })

      assert job.requested_by_type == "system"
      assert job.requested_by_user_id == nil
      assert job.parameters == %{"service" => "sshd"}

      allow(organization, [])

      assert {:error, :capability_not_allowed} =
               Jobs.create_system_job(organization.id, agent.id, "test.restart@1", %{
                 "service" => "sshd"
               })
    end
  end

  describe "lease_jobs/4" do
    setup %{scope: scope, agent: agent} do
      {:ok, job} = Jobs.create_job(scope, agent.id, @collect, %{})
      %{job: job}
    end

    test "leases queued jobs with a one-time token", %{
      scope: scope,
      system_scope: system_scope,
      agent: agent,
      job: job
    } do
      {leased, token} = lease_one(system_scope, agent)

      assert leased.id == job.id
      assert leased.state == "leased"
      assert leased.attempts == 1
      assert is_binary(token)
      refute leased.lease_token_hash == token
      assert DateTime.diff(leased.lease_expires_at, leased.leased_at) == 60
      assert event_types(scope, job) == ["created", "leased"]

      assert {:ok, []} = Jobs.lease_jobs(system_scope, agent, [@collect], 1)
    end

    test "leases only the capabilities the agent will run now", %{
      system_scope: system_scope,
      agent: agent
    } do
      assert {:ok, []} = Jobs.lease_jobs(system_scope, agent, ["test.restart@1"], 5)
      assert {:ok, [_leased]} = Jobs.lease_jobs(system_scope, agent, [@collect], 5)
    end

    test "never leases another agent's or organization's jobs", %{
      organization: organization,
      system_scope: system_scope,
      agent: agent
    } do
      other_agent = agent_fixture(organization)
      assert {:ok, []} = Jobs.lease_jobs(system_scope, other_agent, [@collect], 5)

      %{system_scope: other_scope} = job_organization_fixture()
      assert {:error, :forbidden} = Jobs.lease_jobs(other_scope, agent, [@collect], 5)
    end

    test "fails a job whose capability the organization stopped allowing", %{
      organization: organization,
      system_scope: system_scope,
      agent: agent,
      job: job
    } do
      allow(organization, [])

      assert {:ok, []} = Jobs.lease_jobs(system_scope, agent, [@collect], 5)

      failed = Repo.reload!(job)
      assert failed.state == "failed"
      assert failed.failure_reason == "capability_not_allowed"
    end

    test "skips jobs past their deadline", %{system_scope: system_scope, agent: agent, job: job} do
      job
      |> Ecto.Changeset.change(not_after: DateTime.add(Renga.Time.utc_now_ms(), -1))
      |> Repo.update!()

      assert {:ok, []} = Jobs.lease_jobs(system_scope, agent, [@collect], 5)
    end
  end

  describe "report/6" do
    setup %{scope: scope, system_scope: system_scope, agent: agent} do
      {:ok, _job} = Jobs.create_job(scope, agent.id, @collect, %{})
      {job, token} = lease_one(system_scope, agent)
      %{job: job, token: token}
    end

    test "runs a job to success", %{
      scope: scope,
      system_scope: system_scope,
      agent: agent,
      job: job,
      token: token
    } do
      assert {:ok, running} = Jobs.report(system_scope, agent, job.id, token, "started", %{})
      assert running.state == "running"
      assert running.started_at

      assert {:ok, _job} =
               Jobs.report(system_scope, agent, job.id, token, "progress", %{"step" => "dmi"})

      observation_id = Ecto.UUID.generate()

      assert {:ok, done} =
               Jobs.report(system_scope, agent, job.id, token, "succeeded", %{
                 "result" => %{"observation_id" => observation_id}
               })

      assert done.state == "succeeded"
      assert done.result == %{"observation_id" => observation_id}
      assert done.finished_at
      refute done.lease_token_hash

      assert event_types(scope, job) == ["created", "leased", "started", "progress", "succeeded"]
      assert scope |> Jobs.list_events(job) |> Enum.map(& &1.sequence) == [1, 2, 3, 4, 5]
      assert Enum.all?(Jobs.list_events(scope, job), &(&1.attempt in [0, 1]))
    end

    test "extends the lease on every report", %{
      system_scope: system_scope,
      agent: agent,
      job: job,
      token: token
    } do
      job
      |> Ecto.Changeset.change(lease_expires_at: DateTime.add(Renga.Time.utc_now_ms(), 5))
      |> Repo.update!()

      assert {:ok, running} = Jobs.report(system_scope, agent, job.id, token, "started", %{})
      assert DateTime.diff(running.lease_expires_at, Renga.Time.utc_now_ms()) > 50
    end

    test "rejects reports without the current lease", %{
      system_scope: system_scope,
      organization: organization,
      agent: agent,
      job: job,
      token: token
    } do
      assert {:error, :lease_not_held} =
               Jobs.report(system_scope, agent, job.id, "stale", "started", %{})

      other_agent = agent_fixture(organization)

      assert {:error, :lease_not_held} =
               Jobs.report(system_scope, other_agent, job.id, token, "started", %{})

      job
      |> Ecto.Changeset.change(lease_expires_at: DateTime.add(Renga.Time.utc_now_ms(), -1))
      |> Repo.update!()

      assert {:error, :lease_not_held} =
               Jobs.report(system_scope, agent, job.id, token, "started", %{})
    end

    test "validates results against the capability", %{
      system_scope: system_scope,
      agent: agent,
      job: job,
      token: token
    } do
      assert {:error, %Ecto.Changeset{}} =
               Jobs.report(system_scope, agent, job.id, token, "succeeded", %{"result" => %{}})

      assert Repo.reload!(job).state == "leased"
    end

    test "records failures with their reason", %{
      system_scope: system_scope,
      agent: agent,
      job: job,
      token: token
    } do
      assert {:error, :invalid_failure} =
               Jobs.report(system_scope, agent, job.id, token, "failed", %{})

      assert {:ok, failed} =
               Jobs.report(system_scope, agent, job.id, token, "failed", %{
                 "reason" => "policy_refused"
               })

      assert failed.state == "failed"
      assert failed.failure_reason == "policy_refused"
    end

    test "rejects out-of-order transitions", %{
      system_scope: system_scope,
      agent: agent,
      job: job,
      token: token
    } do
      assert {:ok, _running} = Jobs.report(system_scope, agent, job.id, token, "started", %{})

      assert {:error, :invalid_transition} =
               Jobs.report(system_scope, agent, job.id, token, "started", %{})

      assert {:error, :invalid_transition} =
               Jobs.report(system_scope, agent, job.id, token, "cancelled", %{})

      assert {:error, :invalid_report} =
               Jobs.report(system_scope, agent, job.id, token, "resolved", %{})
    end

    test "bounds the output a job can record", %{
      system_scope: system_scope,
      agent: agent,
      job: job,
      token: token
    } do
      chunk = String.duplicate("x", 40 * 1024)

      assert {:ok, _job} =
               Jobs.report(system_scope, agent, job.id, token, "output", %{"text" => chunk})

      assert {:error, :output_limit_exceeded} =
               Jobs.report(system_scope, agent, job.id, token, "output", %{"text" => chunk})
    end
  end

  describe "cancel_job/2" do
    setup %{scope: scope, agent: agent} do
      {:ok, job} = Jobs.create_job(scope, agent.id, @collect, %{})
      %{job: job}
    end

    test "cancels a queued job at once", %{scope: scope, job: job} do
      assert {:ok, cancelled} = Jobs.cancel_job(scope, job.id)
      assert cancelled.state == "cancelled"
      assert cancelled.finished_at
      assert event_types(scope, job) == ["created", "cancelled"]

      assert {:error, :not_cancellable} = Jobs.cancel_job(scope, job.id)
    end

    test "asks the agent holding a lease to stop", %{
      scope: scope,
      system_scope: system_scope,
      agent: agent,
      job: job
    } do
      {_leased, token} = lease_one(system_scope, agent)

      assert {:ok, requested} = Jobs.cancel_job(scope, job.id)
      assert requested.state == "leased"
      assert requested.cancel_requested_at

      # Asking twice records one request.
      assert {:ok, _same} = Jobs.cancel_job(scope, job.id)

      assert {:ok, progress} = Jobs.report(system_scope, agent, job.id, token, "progress", %{})
      assert progress.cancel_requested_at

      assert {:ok, cancelled} = Jobs.report(system_scope, agent, job.id, token, "cancelled", %{})
      assert cancelled.state == "cancelled"

      assert event_types(scope, job) ==
               ["created", "leased", "cancel_requested", "progress", "cancelled"]
    end

    test "is for owners and admins in the job's organization", %{
      organization: organization,
      job: job
    } do
      assert {:error, :forbidden} = Jobs.cancel_job(member_scope(organization, "member"), job.id)

      %{scope: other_scope} = job_organization_fixture()
      assert {:error, :not_found} = Jobs.cancel_job(other_scope, job.id)
    end

    test "rechecks the role inside the transaction", %{
      organization: organization,
      job: job
    } do
      admin = member_scope(organization, "admin")

      Accounts.OrganizationMembership
      |> where([membership], membership.id == ^admin.membership_id)
      |> Repo.update_all(set: [role: "viewer"])

      assert {:error, :forbidden} = Jobs.cancel_job(admin, job.id)
    end
  end
end
