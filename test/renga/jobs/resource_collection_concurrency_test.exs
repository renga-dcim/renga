defmodule Renga.Jobs.ResourceCollectionConcurrencyTest do
  use ExUnit.Case, async: false

  import Renga.JobsFixtures

  alias Ecto.Adapters.SQL.Sandbox
  alias Renga.Inventory
  alias Renga.Jobs
  alias Renga.Repo

  @collect "inventory.collect@1"

  test "concurrent requests create one open collection and one activity event" do
    :ok = Sandbox.checkout(Repo, sandbox: false)
    context = job_organization_fixture()
    agent = agent_fixture(context.organization)
    resource = reported_resource_fixture(context.organization, agent)
    parent = self()

    try do
      tasks =
        for _ <- 1..2 do
          Task.async(fn ->
            :ok = Sandbox.checkout(Repo, sandbox: false)
            send(parent, {:ready, self()})

            receive do
              :create ->
                Jobs.create_job(context.scope, agent.id, @collect, %{}, resource_id: resource.id)
            after
              5_000 -> exit(:start_timeout)
            end
          end)
        end

      task_pids =
        for _ <- tasks do
          assert_receive {:ready, task_pid}, 5_000
          task_pid
        end

      Enum.each(task_pids, &send(&1, :create))
      results = Enum.map(tasks, &Task.await(&1, 5_000))

      assert [{:error, :resource_collection_open}, {:ok, _job}] = Enum.sort(results)
      assert [_job] = Jobs.list_jobs(context.scope, resource_id: resource.id, group: "open")

      assert [_request] =
               context.scope
               |> Inventory.list_activity()
               |> Enum.filter(&(&1.resource_id == resource.id and &1.kind == "job_requested"))
    after
      Repo.delete!(context.organization)
      Repo.delete!(context.scope.user)
      Sandbox.checkin(Repo)
    end
  end
end
