defmodule Renga.QuotasConcurrencyTest do
  use ExUnit.Case, async: false
  import Renga.JobsFixtures
  alias Ecto.Adapters.SQL.Sandbox
  alias Renga.{Limits, Quotas, Repo}

  for action <- [:set, :clear] do
    @action action
    test "quota policy #{action} and an in-flight resource creation both commit" do
      action = @action
      :ok = Sandbox.checkout(Repo, sandbox: false)
      %{organization: org, scope: owner} = job_organization_fixture()
      actor = Renga.DeploymentAudit.operator("quota-policy-race")
      parent = self()

      try do
        :ok = Limits.set(org, [resources: 5], actor)

        holder =
          Task.async(fn ->
            connected(fn ->
              Repo.transaction(fn ->
                # Model a canonical mutation already holding its tenant fence.
                Repo.query!("SELECT id FROM organizations WHERE id = $1 FOR UPDATE", [
                  Ecto.UUID.dump!(org.id)
                ])

                send(parent, {:held, self()})

                receive do
                  :create ->
                    Renga.Inventory.create_resource(owner, %{
                      kind: "server",
                      name: "during-policy"
                    })
                after
                  5_000 -> flunk("creation was never released")
                end
              end)
            end)
          end)

        assert_receive {:held, holder_pid}

        policy =
          Task.async(fn ->
            connected(fn ->
              %{rows: [[pid]]} = Repo.query!("SELECT pg_backend_pid()")
              send(parent, {:policy, pid})
              change_policy(action, org, actor)
            end)
          end)

        assert_receive {:policy, backend}
        wait_for_lock(backend)
        send(holder_pid, :create)
        assert [{:ok, {:ok, _resource}}, :ok] = Task.await_many([holder, policy], 10_000)
        assert Quotas.usage(org.id, :resources) == 1
      after
        Repo.query!(
          "DELETE FROM deployment_audit_events WHERE organization_id = $1 OR invocation_id = $2",
          [
            Ecto.UUID.dump!(org.id),
            actor.invocation_id
          ]
        )

        Repo.delete!(org)
        Repo.delete!(owner.user)
        Sandbox.checkin(Repo)
      end
    end
  end

  defp change_policy(:set, org, actor), do: Limits.set(org, [resources: 6], actor)
  defp change_policy(:clear, org, actor), do: Limits.clear(org, :resources, actor)

  defp connected(fun) do
    :ok = Sandbox.checkout(Repo, sandbox: false)

    try do
      fun.()
    rescue
      error -> {:failed, error}
    after
      Sandbox.checkin(Repo)
    end
  end

  defp wait_for_lock(backend, attempts \\ 500)

  defp wait_for_lock(_backend, 0),
    do: flunk("policy never reached the concurrent tenant mutation")

  defp wait_for_lock(backend, attempts) do
    case Repo.query!("SELECT wait_event_type FROM pg_stat_activity WHERE pid = $1", [backend]).rows do
      [["Lock"]] ->
        :ok

      _ ->
        Process.sleep(10)
        wait_for_lock(backend, attempts - 1)
    end
  end

  test "two database connections cannot spend the last key slot twice" do
    :ok = Sandbox.checkout(Repo, sandbox: false)
    %{organization: org, scope: owner} = job_organization_fixture()
    actor = Renga.DeploymentAudit.operator("quota-race")

    try do
      :ok = Limits.set(org, [intake_keys: 1], actor)
      parent = self()

      tasks =
        for n <- 1..2 do
          Task.async(fn ->
            connected(fn ->
              send(parent, {:ready, self()})

              receive do
                :go ->
                  # Bypass context locks: the generic quota
                  # ledger itself must serialize independent database writers.
                  %Renga.Inventory.IntakeApiKey{organization_id: org.id}
                  |> Renga.Inventory.IntakeApiKey.create_changeset(
                    %{name: "concurrent-#{n}"},
                    :crypto.strong_rand_bytes(32)
                  )
                  |> Repo.insert()
              end
            end)
          end)
        end

      for _ <- tasks, do: assert_receive({:ready, _pid}, 5_000)
      Enum.each(tasks, &send(&1.pid, :go))
      results = Task.await_many(tasks)
      assert Enum.count(results, &match?({:ok, _}, &1)) == 1
      assert [{:error, reason}] = Enum.filter(results, &match?({:error, _}, &1))
      assert Quotas.exceeded?(reason, :intake_keys)
      assert Quotas.usage(org.id, :intake_keys) == 1
    after
      Repo.query!(
        "DELETE FROM deployment_audit_events WHERE organization_id = $1 OR invocation_id = $2",
        [Ecto.UUID.dump!(org.id), actor.invocation_id]
      )

      Repo.delete!(org)
      Repo.delete!(owner.user)
      Sandbox.checkin(Repo)
    end
  end
end
