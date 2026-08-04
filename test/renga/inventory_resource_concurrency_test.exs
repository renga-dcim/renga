defmodule Renga.InventoryResourceConcurrencyTest do
  use ExUnit.Case, async: false

  alias Ecto.Adapters.SQL.Sandbox
  alias Renga.Accounts
  alias Renga.Inventory
  alias Renga.Repo

  test "concurrent stale updates serialize resource versions and generations" do
    with_resource(fn scope, resource ->
      update_count = 4

      tasks =
        for update <- 1..update_count do
          Task.async(fn ->
            :ok = Sandbox.checkout(Repo, sandbox: false)

            try do
              Inventory.update_resource(scope, resource, %{
                spec: %{"concurrent_update" => update}
              })
            after
              Sandbox.checkin(Repo)
            end
          end)
        end

      results = Task.await_many(tasks)
      assert Enum.all?(results, &match?({:ok, _resource}, &1))

      revisions = Inventory.list_resource_revisions(scope, resource.id)
      persisted = Inventory.get_resource!(scope, resource.id)

      assert Enum.map(revisions, & &1.generation) == Enum.to_list(1..(update_count + 1))
      assert persisted.generation == resource.generation + update_count
      assert persisted.resource_version == revisions |> List.last() |> Map.fetch!(:revision)
    end)
  end

  test "revision allocation is serialized until the allocating transaction commits" do
    with_resources(fn scope, first, second ->
      test_process = self()

      first_task =
        Task.async(fn ->
          :ok = Sandbox.checkout(Repo, sandbox: false)

          try do
            Repo.transaction(fn ->
              result =
                Inventory.update_resource(scope, first, %{display_name: "First updated"})

              send(test_process, :first_revision_allocated)

              receive do
                :commit_first_revision -> result
              end
            end)
          after
            Sandbox.checkin(Repo)
          end
        end)

      assert_receive :first_revision_allocated, 1_000

      second_task =
        Task.async(fn ->
          :ok = Sandbox.checkout(Repo, sandbox: false)

          try do
            Inventory.update_resource(scope, second, %{display_name: "Second updated"})
          after
            Sandbox.checkin(Repo)
          end
        end)

      second_result =
        try do
          Task.yield(second_task, 200)
        after
          send(first_task.pid, :commit_first_revision)
        end

      assert {:ok, {:ok, first_updated}} = Task.await(first_task)

      assert second_result == nil
      assert {:ok, second_updated} = Task.await(second_task)
      assert first_updated.resource_version < second_updated.resource_version
    end)
  end

  defp with_resource(fun) do
    :ok = Sandbox.checkout(Repo, sandbox: false)

    {:ok, organization} =
      Accounts.create_organization(%{
        name: "Concurrent Resource Updates",
        slug: "concurrent-resource-#{System.unique_integer([:positive])}"
      })

    scope = Accounts.scope_for(organization)

    {:ok, resource} =
      Inventory.create_resource(scope, %{
        kind: "server",
        name: "concurrent-resource",
        spec: %{}
      })

    try do
      fun.(scope, resource)
    after
      Repo.delete!(organization)
      Sandbox.checkin(Repo)
    end
  end

  defp with_resources(fun) do
    with_resource(fn scope, first ->
      {:ok, second} =
        Inventory.create_resource(scope, %{
          kind: "server",
          name: "second-concurrent-resource",
          spec: %{}
        })

      fun.(scope, first, second)
    end)
  end
end
