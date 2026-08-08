defmodule Renga.InventoryLockOrderConcurrencyTest do
  use ExUnit.Case, async: false

  alias Ecto.Adapters.SQL.Sandbox
  alias Renga.Accounts
  alias Renga.Inventory
  alias Renga.Inventory.Agent
  alias Renga.Inventory.AgentLease
  alias Renga.Inventory.Observation
  alias Renga.Repo

  @timeout 5_000

  test "authenticated ingestion waits for Organization before locking Source" do
    :ok = Sandbox.checkout(Repo, sandbox: false)
    suffix = System.unique_integer([:positive])

    {:ok, organization} =
      Accounts.create_organization(%{
        name: "Ingestion lock order #{suffix}",
        slug: "ingestion-lock-order-#{suffix}"
      })

    scope = Accounts.scope_for(organization)

    {:ok, {source, token}} =
      Inventory.create_source_with_token(scope, %{kind: "host_agent", name: "agent-#{suffix}"})

    {:ok, authenticated_source} = Inventory.authenticate_source_token(token)

    Repo.query!("BEGIN")
    organization_id = Ecto.UUID.dump!(organization.id)
    source_id = Ecto.UUID.dump!(source.id)

    Repo.query!("SELECT id FROM organizations WHERE id = $1 FOR UPDATE", [organization_id])
    parent = self()

    ingestion =
      Task.async(fn ->
        :ok = Sandbox.checkout(Repo, sandbox: false)
        %{rows: [[backend_pid]]} = Repo.query!("SELECT pg_backend_pid()")
        send(parent, {:ingestion_backend, backend_pid})

        try do
          Inventory.ingest_authenticated_observation(
            scope,
            authenticated_source,
            %{installation_id: Ecto.UUID.generate()},
            %{
              idempotency_key: "lock-order-#{suffix}",
              observed_at: Renga.Time.utc_now_ms(),
              payload: %{}
            }
          )
        after
          Sandbox.checkin(Repo)
        end
      end)

    assert_receive {:ingestion_backend, ingestion_backend_pid}, @timeout

    await_backend_lock_wait!(
      ingestion_backend_pid,
      System.monotonic_time(:millisecond) + @timeout
    )

    probe =
      Task.async(fn ->
        :ok = Sandbox.checkout(Repo, sandbox: false)

        try do
          Repo.query!("SELECT id FROM sources WHERE id = $1 FOR UPDATE NOWAIT", [source_id])
          :source_available
        after
          Sandbox.checkin(Repo)
        end
      end)

    try do
      assert Task.await(probe, @timeout) == :source_available
    after
      Repo.query!("COMMIT")
    end

    assert {:ok, {%Agent{}, %AgentLease{}, %Observation{}, :created}} =
             Task.await(ingestion, @timeout)

    Repo.delete!(organization)
    Sandbox.checkin(Repo)
  end

  defp await_backend_lock_wait!(backend_pid, deadline) do
    Repo.query!("SELECT pg_stat_clear_snapshot()")

    %{rows: rows} =
      Repo.query!(
        """
        SELECT wait_event_type, query
        FROM pg_stat_activity
        WHERE pid = $1
          AND state = 'active'
          AND wait_event_type = 'Lock'
        """,
        [backend_pid]
      )

    case rows do
      [["Lock", query]] ->
        assert query =~ ~r/FROM "organizations"/i
        assert query =~ ~r/FOR UPDATE/i

      [] ->
        if System.monotonic_time(:millisecond) < deadline do
          receive do
          after
            10 -> :ok
          end

          await_backend_lock_wait!(backend_pid, deadline)
        else
          flunk("backend #{backend_pid} did not reach the Organization row-lock wait")
        end
    end
  end
end
