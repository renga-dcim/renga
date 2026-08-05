defmodule Renga.InventoryReconciliationConcurrencyTest do
  use ExUnit.Case, async: false

  alias Ecto.Adapters.SQL.Sandbox
  alias Renga.Accounts
  alias Renga.Inventory
  alias Renga.Repo

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
