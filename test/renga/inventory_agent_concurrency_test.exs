defmodule Renga.InventoryAgentConcurrencyTest do
  use ExUnit.Case, async: false

  alias Ecto.Adapters.SQL.Sandbox
  alias Renga.Accounts
  alias Renga.Inventory
  alias Renga.Inventory.Agent
  alias Renga.Inventory.AgentLease
  alias Renga.Repo

  @timeout 5_000

  test "concurrent initial check-ins converge on one agent and lease" do
    with_source(fn scope, source ->
      parent = self()

      Repo.query!("BEGIN")
      Repo.query!("LOCK TABLE agents IN SHARE MODE")

      tasks =
        for _attempt <- 1..2 do
          Task.async(fn ->
            :ok = Sandbox.checkout(Repo, sandbox: false)
            %{rows: [[backend_pid]]} = Repo.query!("SELECT pg_backend_pid()")

            try do
              send(parent, {:ready, self(), backend_pid})
              Inventory.record_agent_check_in(scope, source.id)
            after
              Sandbox.checkin(Repo)
            end
          end)
        end

      backend_pids =
        Enum.map(tasks, fn task ->
          assert_receive {:ready, task_pid, backend_pid} when task_pid == task.pid, @timeout
          backend_pid
        end)

      try do
        await_initial_check_in_boundary!(
          backend_pids,
          System.monotonic_time(:millisecond) + @timeout
        )
      after
        Repo.query!("COMMIT")
      end

      results = Task.await_many(tasks, @timeout)

      assert Enum.all?(results, &match?({:ok, {%Agent{}, %AgentLease{}}}, &1))

      agent_ids = Enum.map(results, fn {:ok, {agent, _lease}} -> agent.id end)
      lease_ids = Enum.map(results, fn {:ok, {_agent, lease}} -> lease.id end)

      assert agent_ids |> Enum.uniq() |> length() == 1
      assert lease_ids |> Enum.uniq() |> length() == 1
    end)
  end

  test "concurrent first lease renewals converge on one lease" do
    with_source(fn scope, source ->
      {:ok, {agent, lease}} = Inventory.record_agent_check_in(scope, source.id)
      Repo.delete!(lease)

      Repo.query!("BEGIN")
      Repo.query!("LOCK TABLE agent_leases IN SHARE MODE")
      parent = self()

      tasks =
        for _attempt <- 1..2 do
          Task.async(fn ->
            :ok = Sandbox.checkout(Repo, sandbox: false)

            try do
              send(parent, {:ready, self()})
              Inventory.renew_agent_lease(scope, agent.id)
            after
              Sandbox.checkin(Repo)
            end
          end)
        end

      assert_ready_tasks!(tasks)

      try do
        await_blocked_inserts!(
          "agent_leases",
          2,
          System.monotonic_time(:millisecond) + @timeout
        )
      after
        Repo.query!("COMMIT")
      end

      results = Task.await_many(tasks, @timeout)

      assert Enum.all?(results, &match?({:ok, %AgentLease{}}, &1))
      lease_ids = Enum.map(results, fn {:ok, renewed_lease} -> renewed_lease.id end)
      assert lease_ids |> Enum.uniq() |> length() == 1
    end)
  end

  defp with_source(fun) do
    :ok = Sandbox.checkout(Repo, sandbox: false)

    {:ok, organization} =
      Accounts.create_organization(%{
        name: "Concurrent Agent Registration",
        slug: "concurrent-agent-#{System.unique_integer([:positive])}"
      })

    scope = Accounts.scope_for(organization)

    {:ok, source} =
      Inventory.create_source(scope, %{kind: "host_agent", name: "concurrent-host-agent"})

    try do
      fun.(scope, source)
    after
      Repo.delete!(organization)
      Sandbox.checkin(Repo)
    end
  end

  defp await_blocked_inserts!(table, expected, deadline) do
    %{rows: [[blocked]]} =
      Repo.query!(
        """
        SELECT count(*)
        FROM pg_locks AS locks
        JOIN pg_class AS relations ON relations.oid = locks.relation
        WHERE NOT locks.granted
          AND relations.relname = $1
        """,
        [table]
      )

    cond do
      blocked >= expected ->
        :ok

      System.monotonic_time(:millisecond) < deadline ->
        receive do
        after
          10 -> :ok
        end

        await_blocked_inserts!(table, expected, deadline)

      true ->
        flunk("expected #{expected} blocked #{table} inserts, found #{blocked}")
    end
  end

  defp await_initial_check_in_boundary!(backend_pids, deadline) do
    Repo.query!("SELECT pg_stat_clear_snapshot()")

    %{rows: rows} =
      Repo.query!(
        """
        SELECT pid, query
        FROM pg_stat_activity
        WHERE pid = ANY($1)
          AND state = 'active'
          AND wait_event_type = 'Lock'
        """,
        [backend_pids]
      )

    blocked_agent_insert? =
      Enum.any?(rows, fn [_pid, query] -> query =~ ~s(INSERT INTO "agents") end)

    source_waiters =
      for [pid, query] <- rows,
          query =~ ~s(FROM "sources"),
          query =~ "FOR UPDATE",
          do: pid

    cond do
      blocked_agent_insert? and length(source_waiters) == 1 ->
        assert hd(source_waiters) in backend_pids

      System.monotonic_time(:millisecond) < deadline ->
        receive do
        after
          10 -> :ok
        end

        await_initial_check_in_boundary!(backend_pids, deadline)

      true ->
        flunk(
          "expected specific backends #{inspect(backend_pids)} at Agent insert and Source row boundaries, got #{inspect(rows)}"
        )
    end
  end

  defp assert_ready_tasks!(tasks) do
    expected = tasks |> Enum.map(& &1.pid) |> MapSet.new()

    ready =
      Enum.reduce(tasks, MapSet.new(), fn _task, pids ->
        assert_receive {:ready, task_pid}, @timeout
        MapSet.put(pids, task_pid)
      end)

    assert ready == expected
  end
end
