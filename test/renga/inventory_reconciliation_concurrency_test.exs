defmodule Renga.InventoryReconciliationConcurrencyTest do
  use ExUnit.Case, async: false

  alias Ecto.Adapters.SQL.Sandbox
  alias Renga.Accounts
  alias Renga.Catalog
  alias Renga.Inventory
  alias Renga.Repo

  @timeout 5_000

  test "component finding reconciliation waits for catalog resource mutations" do
    :ok = Sandbox.checkout(Repo, sandbox: false)
    suffix = System.unique_integer([:positive])

    {:ok, organization} =
      Accounts.create_organization(%{
        name: "Concurrent component findings #{suffix}",
        slug: "concurrent-component-findings-#{suffix}"
      })

    scope = Accounts.scope_for(organization, %{roles: ["catalog_reconciler"]})
    {:ok, source} = Inventory.create_source(scope, %{kind: "host_agent", name: "agent-#{suffix}"})
    {:ok, resource} = Inventory.create_resource(scope, %{kind: "server", name: "host-#{suffix}"})

    {:ok, observation} =
      Inventory.create_observation(scope, source.id, %{
        idempotency_key: "component-findings-#{suffix}",
        observed_at: ~U[2026-08-01 12:00:00.000Z],
        payload: %{}
      })

    Repo.query!("BEGIN")
    Repo.query!("SELECT id FROM resources WHERE id::text = $1 FOR UPDATE", [resource.id])
    parent = self()

    task =
      Task.async(fn ->
        :ok = Sandbox.checkout(Repo, sandbox: false)

        try do
          Repo.transaction(fn ->
            send(parent, {:ready, self()})
            Catalog.reconcile_component_findings(scope, observation, resource)
          end)
        after
          Sandbox.checkin(Repo)
        end
      end)

    try do
      assert_receive {:ready, task_pid}, @timeout
      assert task_pid == task.pid
      await_row_lock_waiters!(1, @timeout)
    after
      Repo.query!("COMMIT")
    end

    try do
      assert {:ok, :ok} = Task.await(task, @timeout)
    after
      Repo.delete!(organization)
      Sandbox.checkin(Repo)
    end
  end

  test "manual overrides wait for organization reconciliation before materializing" do
    :ok = Sandbox.checkout(Repo, sandbox: false)
    suffix = System.unique_integer([:positive])

    {:ok, organization} =
      Accounts.create_organization(%{
        name: "Concurrent override #{suffix}",
        slug: "concurrent-override-#{suffix}"
      })

    scope = Accounts.scope_for(organization)
    {:ok, user} = Accounts.register_user(%{email: "concurrent-actor-#{suffix}@example.com"})
    scope = %{scope | user: user}
    {:ok, resource} = Inventory.create_resource(scope, %{kind: "server", name: "host-#{suffix}"})

    # This is the same transaction-scoped fence held while reconciliation
    # reads overrides and writes canonical projections.
    Repo.query!("BEGIN")
    Repo.query!("SELECT pg_advisory_xact_lock(hashtextextended($1, 0))", [organization.id])
    parent = self()

    task =
      Task.async(fn ->
        :ok = Sandbox.checkout(Repo, sandbox: false)

        try do
          send(parent, {:ready, self()})

          Inventory.create_resource_override(scope, resource.id, %{
            field: "host.vendor",
            value: %{"value" => "Operator Vendor"}
          })
        after
          Sandbox.checkin(Repo)
        end
      end)

    try do
      assert_receive {:ready, task_pid}, @timeout
      assert task_pid == task.pid
      await_advisory_waiters!(1, @timeout)
    after
      # End the transaction holding the organization fence.
      Repo.query!("COMMIT")
    end

    try do
      assert {:ok, override} = Task.await(task, @timeout)
      host = Inventory.get_host_by_resource!(scope, resource.id)
      assert host.vendor == "Operator Vendor"
      assert host.metadata["field_owners"]["vendor"]["override_id"] == override.id
    after
      Repo.delete!(organization)
      Sandbox.checkin(Repo)
    end
  end

  test "concurrent ingestion reconciles an immutable observation only once" do
    :ok = Sandbox.checkout(Repo, sandbox: false)
    suffix = System.unique_integer([:positive])

    {:ok, organization} =
      Accounts.create_organization(%{
        name: "Concurrent ingestion #{suffix}",
        slug: "concurrent-ingestion-#{suffix}"
      })

    scope = Accounts.scope_for(organization)
    {:ok, source} = Inventory.create_source(scope, %{kind: "host_agent", name: "agent-#{suffix}"})

    {:ok, observation} =
      Inventory.create_observation(scope, source.id, %{
        idempotency_key: "ingestion-#{suffix}",
        observed_at: ~U[2026-08-01 12:00:00.000Z],
        payload: %{
          "resources" => [
            %{
              "kind" => "server",
              "identifiers" => %{"machine_id" => "machine-#{suffix}"},
              "attributes" => %{},
              "interfaces" => []
            }
          ]
        }
      })

    tasks =
      for _ <- 1..2 do
        Task.async(fn ->
          :ok = Sandbox.checkout(Repo, sandbox: false)

          try do
            Inventory.reconcile_observation_once(scope, observation.id)
          after
            Sandbox.checkin(Repo)
          end
        end)
      end

    try do
      assert Enum.all?(Task.await_many(tasks, @timeout), &match?({:ok, %{}, _}, &1))

      assert [%{attempt: 1, status: "succeeded"}] =
               Inventory.list_observation_reconciliations(scope, observation.id)
    after
      Repo.delete!(organization)
      Sandbox.checkin(Repo)
    end
  end

  test "concurrent failed ingestion records one terminal attempt" do
    :ok = Sandbox.checkout(Repo, sandbox: false)
    suffix = System.unique_integer([:positive])

    {:ok, organization} =
      Accounts.create_organization(%{
        name: "Concurrent failed ingestion #{suffix}",
        slug: "concurrent-failed-ingestion-#{suffix}"
      })

    scope = Accounts.scope_for(organization)
    {:ok, source} = Inventory.create_source(scope, %{kind: "host_agent", name: "agent-#{suffix}"})

    {:ok, observation} =
      Inventory.create_observation(scope, source.id, %{
        idempotency_key: "failed-ingestion-#{suffix}",
        observed_at: ~U[2026-08-01 12:00:00.000Z],
        payload: %{
          "resources" => [
            %{
              "kind" => "server",
              "identifiers" => %{"machine_id" => "machine-#{suffix}"},
              "attributes" => %{"vendor" => %{"invalid" => true}},
              "interfaces" => []
            }
          ]
        }
      })

    Repo.query!("BEGIN")
    Repo.query!("SELECT pg_advisory_xact_lock(hashtextextended($1, 0))", [organization.id])
    parent = self()

    tasks =
      for _ <- 1..2 do
        Task.async(fn ->
          :ok = Sandbox.checkout(Repo, sandbox: false)

          try do
            send(parent, {:ready, self()})
            Inventory.reconcile_observation_once(scope, observation.id)
          after
            Sandbox.checkin(Repo)
          end
        end)
      end

    try do
      await_task_readiness!(tasks)
      await_advisory_waiters!(2, @timeout)
    after
      Repo.query!("COMMIT")
    end

    try do
      assert Enum.all?(
               Task.await_many(tasks, @timeout),
               &match?({:error, %{status: "failed"}}, &1)
             )

      assert [%{attempt: 1, status: "failed"}] =
               Inventory.list_observation_reconciliations(scope, observation.id)
    after
      Repo.delete!(organization)
      Sandbox.checkin(Repo)
    end
  end

  test "concurrent unexpected failures retain distinct terminal attempts" do
    :ok = Sandbox.checkout(Repo, sandbox: false)
    suffix = System.unique_integer([:positive])

    {:ok, organization} =
      Accounts.create_organization(%{
        name: "Concurrent reconciliation #{suffix}",
        slug: "concurrent-reconciliation-#{suffix}"
      })

    scope = Accounts.scope_for(organization)
    {:ok, source} = Inventory.create_source(scope, %{kind: "host_agent", name: "agent-#{suffix}"})

    {:ok, observation} =
      Inventory.create_observation(scope, source.id, %{
        idempotency_key: "failure-#{suffix}",
        observed_at: ~U[2026-08-01 12:00:00.000Z],
        payload: %{
          "resources" => [
            %{
              "kind" => "server",
              "identifiers" => %{"machine_id" => "machine-#{suffix}"},
              "attributes" => %{"vendor" => %{"invalid" => true}},
              "interfaces" => []
            }
          ]
        }
      })

    barrier_key = suffix
    install_insert_barrier!(organization.id, barrier_key)
    Repo.query!("SELECT pg_advisory_lock($1)", [barrier_key])
    parent = self()

    tasks =
      for _ <- 1..2 do
        Task.async(fn ->
          :ok = Sandbox.checkout(Repo, sandbox: false)

          try do
            send(parent, {:ready, self()})
            Inventory.reconcile_observation(scope, observation.id)
          after
            Sandbox.checkin(Repo)
          end
        end)
      end

    try do
      # Readiness proves both recorders started the contested operation; an
      # insert waiter proves reconciliation reached the database barrier.
      await_task_readiness!(tasks)
      wait_for_insert_barrier(1, @timeout)
    after
      Repo.query!("SELECT pg_advisory_unlock($1)", [barrier_key])
    end

    try do
      assert Enum.all?(
               Task.await_many(tasks, @timeout),
               &match?({:error, %{status: "failed"}}, &1)
             )

      assert [
               %{attempt: 1, status: "failed"},
               %{attempt: 2, status: "failed"}
             ] = Inventory.list_observation_reconciliations(scope, observation.id)
    after
      Repo.query!("DROP TRIGGER reconciliation_failure_barrier ON observation_reconciliations")
      Repo.query!("DROP FUNCTION reconciliation_failure_barrier()")
      Repo.delete!(organization)
      Sandbox.checkin(Repo)
    end
  end

  defp install_insert_barrier!(organization_id, barrier_key) do
    Repo.query!("""
    CREATE FUNCTION reconciliation_failure_barrier() RETURNS trigger AS $$
    BEGIN
      IF NEW.organization_id = '#{organization_id}'::uuid THEN
        PERFORM pg_advisory_xact_lock(#{barrier_key});
      END IF;
      RETURN NEW;
    END;
    $$ LANGUAGE plpgsql
    """)

    Repo.query!("""
    CREATE TRIGGER reconciliation_failure_barrier
    BEFORE INSERT ON observation_reconciliations
    FOR EACH ROW EXECUTE FUNCTION reconciliation_failure_barrier()
    """)
  end

  defp wait_for_insert_barrier(expected, timeout) do
    deadline = System.monotonic_time(:millisecond) + timeout

    do_wait_for_insert_barrier(expected, deadline)
  end

  defp do_wait_for_insert_barrier(expected, deadline) do
    receive do
    after
      10 -> :ok
    end

    [[count]] =
      Repo.query!("""
      SELECT count(*)
      FROM pg_stat_activity
      WHERE wait_event = 'advisory'
        AND query LIKE 'INSERT INTO "observation_reconciliations"%'
      """).rows

    cond do
      count >= expected ->
        :ok

      System.monotonic_time(:millisecond) < deadline ->
        do_wait_for_insert_barrier(expected, deadline)

      true ->
        flunk("expected #{expected} reconciliation inserts at advisory barrier, found #{count}")
    end
  end

  defp await_task_readiness!(tasks) do
    expected = tasks |> Enum.map(& &1.pid) |> MapSet.new()

    ready =
      Enum.reduce(tasks, MapSet.new(), fn _task, pids ->
        assert_receive {:ready, task_pid}, @timeout
        MapSet.put(pids, task_pid)
      end)

    assert ready == expected
  end

  defp await_advisory_waiters!(expected, timeout) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_await_advisory_waiters!(expected, deadline)
  end

  defp do_await_advisory_waiters!(expected, deadline) do
    [[count]] =
      Repo.query!("SELECT count(*) FROM pg_stat_activity WHERE wait_event = 'advisory'").rows

    cond do
      count >= expected ->
        :ok

      System.monotonic_time(:millisecond) >= deadline ->
        flunk("expected #{expected} advisory-lock waiters, found #{count}")

      true ->
        receive do
        after
          10 -> :ok
        end

        do_await_advisory_waiters!(expected, deadline)
    end
  end

  defp await_row_lock_waiters!(expected, timeout) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_await_row_lock_waiters!(expected, deadline)
  end

  defp do_await_row_lock_waiters!(expected, deadline) do
    [[count]] =
      Repo.query!("""
      SELECT count(*)
      FROM pg_stat_activity
      WHERE wait_event_type = 'Lock'
      """).rows

    cond do
      count >= expected ->
        :ok

      System.monotonic_time(:millisecond) >= deadline ->
        flunk("expected #{expected} resource row-lock waiters, found #{count}")

      true ->
        receive do
        after
          10 -> :ok
        end

        do_await_row_lock_waiters!(expected, deadline)
    end
  end
end
