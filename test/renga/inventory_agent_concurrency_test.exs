defmodule Renga.InventoryAgentConcurrencyTest do
  use ExUnit.Case, async: false

  alias Ecto.Adapters.SQL.Sandbox
  alias Renga.Accounts
  alias Renga.Inventory
  alias Renga.Inventory.Agent
  alias Renga.Inventory.AgentLease
  alias Renga.Repo

  test "concurrent initial check-ins converge on one agent and lease" do
    with_source(fn scope, source ->
      parent = self()

      tasks =
        for _attempt <- 1..2 do
          Task.async(fn ->
            :ok = Sandbox.checkout(Repo, sandbox: false)

            try do
              send(parent, {:ready, self()})

              receive do
                :start -> :ok
              end

              Inventory.record_agent_check_in(scope, source.id)
            after
              Sandbox.checkin(Repo)
            end
          end)
        end

      task_pids = Enum.map(tasks, & &1.pid)
      Enum.each(task_pids, fn task_pid -> assert_receive {:ready, ^task_pid} end)
      Enum.each(task_pids, &send(&1, :start))

      results = Task.await_many(tasks)

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

      tasks =
        for _attempt <- 1..2 do
          Task.async(fn ->
            :ok = Sandbox.checkout(Repo, sandbox: false)

            try do
              Inventory.renew_agent_lease(scope, agent.id)
            after
              Sandbox.checkin(Repo)
            end
          end)
        end

      try do
        await_blocked_inserts!(
          "agent_leases",
          2,
          System.monotonic_time(:millisecond) + 2_000
        )
      after
        Repo.query!("COMMIT")
      end

      results = Task.await_many(tasks)

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
        Process.sleep(10)
        await_blocked_inserts!(table, expected, deadline)

      true ->
        flunk("expected #{expected} blocked #{table} inserts, found #{blocked}")
    end
  end
end
