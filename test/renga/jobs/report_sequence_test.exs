defmodule Renga.Jobs.ReportSequenceTest do
  use Renga.DataCase, async: true

  import Renga.JobsFixtures

  alias Renga.Jobs

  @collect "inventory.collect@1"

  setup do
    %{organization: organization, scope: scope, system_scope: system_scope} =
      context = job_organization_fixture()

    agent = agent_fixture(organization)
    {:ok, _job} = Jobs.create_job(scope, agent.id, @collect, %{})
    {:ok, [{job, token}]} = Jobs.lease_jobs(system_scope, agent, [@collect], 1)

    Map.merge(context, %{agent: agent, job: job, token: token})
  end

  defp report(context, type, payload, sequence, token \\ nil) do
    Jobs.report(
      context.system_scope,
      context.agent,
      context.job.id,
      token || context.token,
      type,
      payload,
      sequence: sequence
    )
  end

  defp event_types(%{scope: scope, job: job}),
    do: scope |> Jobs.list_events(job) |> Enum.map(& &1.type)

  test "a retried report is recorded once", context do
    assert {:ok, %{state: "running"}} = report(context, "started", %{}, 1)
    assert {:ok, %{output_bytes: bytes}} = report(context, "progress", %{"step" => "dmi"}, 2)
    assert {:ok, %{output_bytes: ^bytes}} = report(context, "progress", %{"step" => "dmi"}, 2)

    assert event_types(context) == ~w(created leased started progress)
  end

  test "a retried final report returns the recorded outcome after the lease is released",
       context do
    result = %{"result" => %{"observation_id" => Ecto.UUID.generate()}}

    {:ok, _running} = report(context, "started", %{}, 1)
    assert {:ok, %{state: "succeeded"} = done} = report(context, "succeeded", result, 2)
    assert {:ok, ^done} = report(context, "succeeded", result, 2)

    assert event_types(context) == ~w(created leased started succeeded)
  end

  test "rejects a sequence reused for another report or numbered below one recorded",
       context do
    {:ok, _running} = report(context, "started", %{}, 1)
    {:ok, _job} = report(context, "progress", %{}, 3)

    assert {:error, :sequence_conflict} = report(context, "output", %{}, 3)
    assert {:error, :stale_sequence} = report(context, "output", %{}, 2)
    assert {:ok, _job} = report(context, "output", %{}, 4)
  end

  test "a sequence from a lost lease never matches the next attempt", context do
    {:ok, _running} = report(context, "started", %{}, 1)
    # The lease lapses; inventory.collect is idempotent, so the job requeues.
    %{lapsed: 1} = Jobs.sweep(DateTime.add(Renga.Time.utc_now_ms(), 120))
    {:ok, [{_job, token}]} = Jobs.lease_jobs(context.system_scope, context.agent, [@collect], 1)

    # The old holder retrying its report is told it lost the lease.
    assert {:error, :lease_not_held} = report(context, "progress", %{}, 2)
    assert {:ok, %{state: "running", attempts: 2}} = report(context, "started", %{}, 1, token)
  end

  test "only the reporting agent can replay its report", context do
    {:ok, _running} = report(context, "started", %{}, 1)
    other = agent_fixture(context.organization)

    assert {:error, :lease_not_held} = report(%{context | agent: other}, "started", %{}, 1)
  end

  test "requires a positive integer sequence", context do
    for sequence <- [0, -1, "1", 1.0] do
      assert {:error, :invalid_report} = report(context, "started", %{}, sequence)
    end
  end
end
