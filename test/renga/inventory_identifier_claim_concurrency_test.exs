defmodule Renga.InventoryIdentifierClaimConcurrencyTest do
  use ExUnit.Case, async: false

  import Ecto.Query

  alias Ecto.Adapters.SQL.Sandbox
  alias Renga.Accounts
  alias Renga.Inventory
  alias Renga.Inventory.ResourceIdentifierClaim
  alias Renga.Repo

  test "concurrent out-of-order claims preserve the earliest first seen time" do
    :ok = Sandbox.checkout(Repo, sandbox: false)
    suffix = System.unique_integer([:positive])

    {:ok, organization} =
      Accounts.create_organization(%{
        name: "Concurrent identifier claims #{suffix}",
        slug: "concurrent-identifier-claims-#{suffix}"
      })

    scope = Accounts.scope_for(organization)
    {:ok, source} = Inventory.create_source(scope, %{kind: "host_agent", name: "agent-#{suffix}"})

    {:ok, earlier_observation} =
      Inventory.create_observation(scope, source.id, %{
        idempotency_key: "earlier-#{suffix}",
        observed_at: ~U[2026-07-01 12:00:00.000Z],
        payload: %{}
      })

    {:ok, later_observation} =
      Inventory.create_observation(scope, source.id, %{
        idempotency_key: "later-#{suffix}",
        observed_at: ~U[2026-08-01 12:00:00.000Z],
        payload: %{}
      })

    barrier_key = suffix
    install_insert_barrier!(organization.id, barrier_key)
    Repo.query!("SELECT pg_advisory_lock($1)", [barrier_key])

    tasks =
      for observation <- [later_observation, earlier_observation] do
        Task.async(fn ->
          :ok = Sandbox.checkout(Repo, sandbox: false)

          try do
            Inventory.create_resource_identifier_claim(scope, source.id, observation.id, %{
              kind: "machine_id",
              value: "machine-#{suffix}"
            })
          after
            Sandbox.checkin(Repo)
          end
        end)
      end

    try do
      # Without claim-key serialization both transactions read empty history and
      # reach this barrier; with it, only the lock holder reaches the insert.
      wait_for_insert_barrier(2, 1_000)
    after
      Repo.query!("SELECT pg_advisory_unlock($1)", [barrier_key])
    end

    try do
      assert Enum.all?(Task.await_many(tasks), &match?({:ok, _claim}, &1))

      claims =
        Repo.all(
          from claim in ResourceIdentifierClaim,
            where: claim.organization_id == ^organization.id,
            where: claim.normalized_value == ^"machine-#{suffix}"
        )

      assert length(claims) == 2
      assert Enum.all?(claims, &(&1.first_seen_at == earlier_observation.observed_at))
    after
      Repo.query!("DROP TRIGGER identifier_claim_insert_barrier ON resource_identifier_claims")
      Repo.query!("DROP FUNCTION identifier_claim_insert_barrier()")
      Repo.delete!(organization)
      Sandbox.checkin(Repo)
    end
  end

  defp install_insert_barrier!(organization_id, barrier_key) do
    Repo.query!("""
    CREATE FUNCTION identifier_claim_insert_barrier() RETURNS trigger AS $$
    BEGIN
      IF NEW.organization_id = '#{organization_id}'::uuid THEN
        PERFORM pg_advisory_xact_lock(#{barrier_key});
      END IF;
      RETURN NEW;
    END;
    $$ LANGUAGE plpgsql
    """)

    Repo.query!("""
    CREATE TRIGGER identifier_claim_insert_barrier
    BEFORE INSERT ON resource_identifier_claims
    FOR EACH ROW EXECUTE FUNCTION identifier_claim_insert_barrier()
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
        AND query LIKE 'INSERT INTO "resource_identifier_claims"%'
      """).rows

    if count < expected and System.monotonic_time(:millisecond) < deadline,
      do: do_wait_for_insert_barrier(expected, deadline)
  end
end
