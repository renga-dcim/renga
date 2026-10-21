defmodule Renga.Jobs.SweepConcurrencyTest do
  use ExUnit.Case, async: false

  import Ecto.Query
  import Renga.JobsFixtures

  alias Ecto.Adapters.SQL.Sandbox
  alias Renga.Jobs
  alias Renga.Jobs.Job
  alias Renga.Repo

  @restart "test.restart@1"

  # Binding changes lock the organization FOR UPDATE and then the queued
  # jobs under the old binding. A sweep that locked the job first would
  # then wait on the organization to insert the job's event (its foreign
  # key takes KEY SHARE on the parent row), and the two would deadlock. So
  # a sweep takes the organization before the job.
  test "a sweep waits for the organization before it locks a job" do
    :ok = Sandbox.checkout(Repo, sandbox: false)
    %{organization: organization} = job_organization_fixture()

    try do
      organization
      |> Ecto.Changeset.change(settings: %{"jobs" => %{"allowed_capabilities" => [@restart]}})
      |> Repo.update!()

      agent = agent_fixture(organization, [@restart])
      bound = target_binding_fixture(organization, agent)

      {:ok, job} =
        Jobs.create_system_job(organization.id, agent.id, @restart, %{"service" => "sshd"},
          resource_id: bound.resource.id
        )

      test_process = self()

      {:ok, sweep} =
        Repo.transaction(fn ->
          Repo.query!("SELECT id FROM organizations WHERE id = $1::text::uuid FOR UPDATE", [
            organization.id
          ])

          sweep = sweep_task(test_process, DateTime.add(job.not_after, 1))
          assert_receive {:sweep_backend, backend_pid}, 5_000
          assert waits_for_lock?(backend_pid), "the sweep never waited for a lock"

          # What a binding change does next: the job must still be free.
          assert [_job] =
                   Job
                   |> where([queued], queued.id == ^job.id)
                   |> lock("FOR UPDATE NOWAIT")
                   |> Repo.all()

          sweep
        end)

      assert %{expired: expired} = Task.await(sweep, 5_000)
      assert expired >= 1
      assert Repo.reload!(job).state == "expired"
    after
      # This test runs outside the sandbox, so it removes the people the
      # fixtures created too; leftover emails would collide with later runs.
      user_ids =
        Repo.all(
          from membership in Renga.Accounts.OrganizationMembership,
            where: membership.organization_id == ^organization.id,
            select: membership.user_id
        )

      Repo.delete!(organization)
      Repo.delete_all(from user in Renga.Accounts.User, where: user.id in ^user_ids)
      Sandbox.checkin(Repo)
    end
  end

  defp sweep_task(test_process, now) do
    Task.async(fn ->
      :ok = Sandbox.checkout(Repo, sandbox: false)

      try do
        %{rows: [[backend_pid]]} = Repo.query!("SELECT pg_backend_pid()")
        send(test_process, {:sweep_backend, backend_pid})
        Jobs.sweep(now)
      after
        Sandbox.checkin(Repo)
      end
    end)
  end

  defp waits_for_lock?(backend_pid) do
    Enum.reduce_while(1..500, false, fn _, _ ->
      Repo.query!("SELECT pg_stat_clear_snapshot()")

      case Repo.query!("SELECT wait_event_type FROM pg_stat_activity WHERE pid = $1", [
             backend_pid
           ]).rows do
        [["Lock"]] ->
          {:halt, true}

        _other ->
          Process.sleep(10)
          {:cont, false}
      end
    end)
  end
end
