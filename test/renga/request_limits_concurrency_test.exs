defmodule Renga.RequestLimitsConcurrencyTest do
  use ExUnit.Case, async: false
  import Renga.JobsFixtures
  alias Ecto.Adapters.SQL.Sandbox
  alias Renga.{Limits, Repo, RequestLimits}

  test "independent database connections cannot both spend the last request" do
    :ok = Sandbox.checkout(Repo, sandbox: false)
    %{organization: organization, scope: scope} = job_organization_fixture()

    try do
      :ok =
        Limits.set(
          organization,
          [http_organization_rate: 1],
          Renga.DeploymentAudit.operator("test")
        )

      parent = self()

      tasks =
        for _ <- 1..2 do
          Task.async(fn ->
            :ok = Sandbox.checkout(Repo, sandbox: false)
            send(parent, {:ready, self()})

            try do
              receive do
                :go -> RequestLimits.check(scope, :http, 125)
              end
            after
              Sandbox.checkin(Repo)
            end
          end)
        end

      for _ <- tasks, do: assert_receive({:ready, _pid}, 5_000)
      Enum.each(tasks, &send(&1.pid, :go))
      assert Enum.sort(Task.await_many(tasks)) == [:ok, {:error, 55}]
    after
      Repo.query!("DELETE FROM deployment_audit_events WHERE organization_id = $1", [
        Ecto.UUID.dump!(organization.id)
      ])

      Repo.delete!(organization)
      Repo.delete!(scope.user)
      Sandbox.checkin(Repo)
    end
  end
end
