defmodule Renga.InventoryResourceConcurrencyTest do
  use ExUnit.Case, async: false

  alias Ecto.Adapters.SQL.Sandbox
  alias Renga.Accounts
  alias Renga.Inventory
  alias Renga.Repo

  test "concurrent stale updates allow one winner and reject the rest" do
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
      {successful, stale} = Enum.split_with(results, &match?({:ok, _resource}, &1))

      assert length(successful) == 1
      assert length(stale) == update_count - 1

      assert Enum.all?(stale, fn {:error, changeset} ->
               Keyword.has_key?(changeset.errors, :resource_version)
             end)

      revisions = Inventory.list_resource_revisions(scope, resource.id)
      persisted = Inventory.get_resource!(scope, resource.id)

      assert Enum.map(revisions, & &1.generation) == [1, 2]
      assert persisted.generation == resource.generation + 1
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

  test "revision allocation in one organization does not wait on another (RFD 21)" do
    with_resource(fn scope, first ->
      {other_organization, other_scope, other} = organization_with_resource()

      try do
        test_process = self()

        holder =
          Task.async(fn ->
            :ok = Sandbox.checkout(Repo, sandbox: false)

            try do
              Repo.transaction(fn ->
                result = Inventory.update_resource(scope, first, %{display_name: "Held"})
                send(test_process, :revision_held)

                receive do
                  :commit -> result
                end
              end)
            after
              Sandbox.checkin(Repo)
            end
          end)

        assert_receive :revision_held, 1_000

        other_task =
          Task.async(fn ->
            :ok = Sandbox.checkout(Repo, sandbox: false)

            try do
              Inventory.update_resource(other_scope, other, %{display_name: "Not blocked"})
            after
              Sandbox.checkin(Repo)
            end
          end)

        other_result =
          try do
            Task.yield(other_task, 1_000)
          after
            send(holder.pid, :commit)
          end

        assert {:ok, {:ok, _other_updated}} = other_result
        assert {:ok, {:ok, _first_updated}} = Task.await(holder)
      after
        Repo.delete!(other_organization)
      end
    end)
  end

  test "an allocator still taking the pre-RFD 21 global lock excludes current allocators" do
    with_resource(fn scope, resource ->
      test_process = self()

      legacy_writer =
        Task.async(fn ->
          :ok = Sandbox.checkout(Repo, sandbox: false)

          try do
            Repo.transaction(fn ->
              Repo.query!("SELECT pg_advisory_xact_lock($1)", [1_380_271_687])
              send(test_process, :legacy_lock_held)

              receive do
                :commit -> :ok
              end
            end)
          after
            Sandbox.checkin(Repo)
          end
        end)

      assert_receive :legacy_lock_held, 1_000

      current_writer =
        Task.async(fn ->
          :ok = Sandbox.checkout(Repo, sandbox: false)

          try do
            Inventory.update_resource(scope, resource, %{display_name: "After legacy"})
          after
            Sandbox.checkin(Repo)
          end
        end)

      blocked =
        try do
          Task.yield(current_writer, 200)
        after
          send(legacy_writer.pid, :commit)
        end

      assert blocked == nil
      assert {:ok, :ok} = Task.await(legacy_writer)
      assert {:ok, updated} = Task.await(current_writer)

      # And the other way round: while a current allocator holds its
      # revision, a legacy allocator cannot take the global lock.
      current_holder =
        Task.async(fn ->
          :ok = Sandbox.checkout(Repo, sandbox: false)

          try do
            Repo.transaction(fn ->
              result = Inventory.update_resource(scope, updated, %{display_name: "Held"})
              send(test_process, :current_revision_held)

              receive do
                :commit -> result
              end
            end)
          after
            Sandbox.checkin(Repo)
          end
        end)

      assert_receive :current_revision_held, 1_000

      legacy_available =
        try do
          Repo.transaction(fn ->
            Repo.query!("SELECT pg_try_advisory_xact_lock($1)", [1_380_271_687]).rows
          end)
        after
          send(current_holder.pid, :commit)
        end

      assert legacy_available == {:ok, [[false]]}
      assert {:ok, {:ok, _resource}} = Task.await(current_holder)
    end)
  end

  test "concurrent initial condition puts both succeed" do
    with_resource(fn scope, resource ->
      test_process = self()

      first_task =
        Task.async(fn ->
          :ok = Sandbox.checkout(Repo, sandbox: false)

          try do
            Repo.transaction(fn ->
              result =
                Inventory.put_resource_condition(scope, resource.id, %{
                  type: "Ready",
                  status: "true"
                })

              send(test_process, :first_condition_inserted)

              receive do
                :commit_first_condition -> result
              end
            end)
          after
            Sandbox.checkin(Repo)
          end
        end)

      assert_receive :first_condition_inserted, 1_000

      second_task =
        Task.async(fn ->
          :ok = Sandbox.checkout(Repo, sandbox: false)

          try do
            Inventory.put_resource_condition(scope, resource.id, %{
              type: "Ready",
              status: "true"
            })
          after
            Sandbox.checkin(Repo)
          end
        end)

      second_result =
        try do
          Task.yield(second_task, 200)
        after
          send(first_task.pid, :commit_first_condition)
        end

      assert {:ok, {:ok, first_condition}} = Task.await(first_task)
      assert second_result == nil
      assert {:ok, second_condition} = Task.await(second_task)
      assert second_condition.id == first_condition.id
    end)
  end

  defp with_resource(fun) do
    :ok = Sandbox.checkout(Repo, sandbox: false)
    {organization, scope, resource} = organization_with_resource()

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

  defp organization_with_resource do
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

    {organization, scope, resource}
  end
end
