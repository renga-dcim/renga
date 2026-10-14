defmodule Renga.Jobs.JobEventTest do
  @moduledoc """
  Job events are the job's history, so the database itself refuses to change
  or remove them while their job and organization exist.
  """

  use Renga.DataCase, async: true

  import Renga.JobsFixtures

  alias Renga.Jobs.Job
  alias Renga.Jobs.JobEvent

  setup do
    %{organization: organization} = job_organization_fixture()
    agent = agent_fixture(organization)

    job =
      Repo.insert!(%Job{
        organization_id: organization.id,
        agent_id: agent.id,
        capability: "inventory.collect",
        capability_version: 1,
        risk_class: "observe",
        retry_class: "idempotent",
        requested_by_type: "system",
        state: "queued",
        max_attempts: 3,
        not_after: DateTime.add(Renga.Time.utc_now_ms(), 3600),
        output_limit_bytes: 65_536,
        timeout_ms: 300_000,
        last_sequence: 1
      })

    event =
      Repo.insert!(%JobEvent{
        organization_id: organization.id,
        job_id: job.id,
        sequence: 1,
        attempt: 0,
        type: "created",
        actor_type: "system"
      })

    %{organization: organization, job: job, event: event}
  end

  test "rejects updates", %{event: event} do
    assert_raise Postgrex.Error, ~r/job events are append-only/, fn ->
      event |> Ecto.Changeset.change(type: "failed") |> Repo.update!()
    end
  end

  test "rejects deletes while the job exists", %{event: event} do
    assert_raise Postgrex.Error, ~r/job events are append-only/, fn ->
      Repo.delete!(event)
    end
  end

  test "go with their job", %{job: job, event: event} do
    Repo.delete!(job)
    refute Repo.reload(event)
  end

  test "go with their organization", %{organization: organization, event: event} do
    Repo.delete!(organization)
    refute Repo.reload(event)
  end

  test "keeps a tenant's events on its own jobs", %{job: job} do
    %{organization: other} = job_organization_fixture()

    assert_raise Ecto.ConstraintError, ~r/job_events_tenant_job_fkey/, fn ->
      Repo.insert!(%JobEvent{
        organization_id: other.id,
        job_id: job.id,
        sequence: 2,
        attempt: 0,
        type: "created",
        actor_type: "system"
      })
    end
  end

  test "rejects a held lease without its token", %{job: job} do
    assert_raise Ecto.ConstraintError, ~r/jobs_lease_shape/, fn ->
      job |> Ecto.Changeset.change(state: "leased") |> Repo.update!()
    end
  end
end
