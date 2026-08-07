defmodule Renga.InventoryReconciliationConcurrencyTest do
  use ExUnit.Case, async: false

  alias Ecto.Adapters.SQL.Sandbox
  alias Renga.Accounts
  alias Renga.Inventory
  alias Renga.Repo

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

    task =
      Task.async(fn ->
        :ok = Sandbox.checkout(Repo, sandbox: false)

        try do
          Inventory.create_resource_override(scope, resource.id, %{
            field: "host.vendor",
            value: %{"value" => "Operator Vendor"}
          })
        after
          Sandbox.checkin(Repo)
        end
      end)

    try do
      assert wait_for_advisory_lock(task.pid, 1_000),
             "override materialization raced the reconciliation fence"
    after
      # End the transaction holding the organization fence.
      Repo.query!("COMMIT")
    end

    try do
      assert {:ok, override} = Task.await(task)
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
      assert Enum.all?(Task.await_many(tasks), &match?({:ok, %{}, _}, &1))

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
      Process.sleep(100)
      assert Enum.all?(tasks, &Process.alive?(&1.pid))
    after
      Repo.query!("COMMIT")
    end

    try do
      assert Enum.all?(Task.await_many(tasks), &match?({:error, %{status: "failed"}}, &1))

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

    tasks =
      for _ <- 1..2 do
        Task.async(fn ->
          :ok = Sandbox.checkout(Repo, sandbox: false)

          try do
            Inventory.reconcile_observation(scope, observation.id)
          after
            Sandbox.checkin(Repo)
          end
        end)
      end

    try do
      # Before serialization both recorders reach the insert barrier after
      # independently choosing attempt 1. Afterwards only the lock holder can.
      wait_for_insert_barrier(2, 1_000)
    after
      Repo.query!("SELECT pg_advisory_unlock($1)", [barrier_key])
    end

    try do
      assert Enum.all?(Task.await_many(tasks), &match?({:error, %{status: "failed"}}, &1))

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

  defp wait_for_advisory_lock(pid, timeout) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_wait_for_advisory_lock(pid, deadline)
  end

  defp do_wait_for_advisory_lock(pid, deadline) do
    [[waiting?]] =
      Repo.query!("""
      SELECT EXISTS (
        SELECT 1
        FROM pg_stat_activity
        WHERE wait_event = 'advisory'
          AND query LIKE 'SELECT pg_advisory_xact_lock(hashtextextended%'
      )
      """).rows

    cond do
      waiting? -> true
      not Process.alive?(pid) -> false
      System.monotonic_time(:millisecond) >= deadline -> false
      true -> Process.sleep(10) && do_wait_for_advisory_lock(pid, deadline)
    end
  end

  defp do_wait_for_insert_barrier(expected, deadline) do
    Process.sleep(10)

    [[count]] =
      Repo.query!("""
      SELECT count(*)
      FROM pg_stat_activity
      WHERE wait_event = 'advisory'
        AND query LIKE 'INSERT INTO "observation_reconciliations"%'
      """).rows

    if count < expected and System.monotonic_time(:millisecond) < deadline,
      do: do_wait_for_insert_barrier(expected, deadline)
  end
end
