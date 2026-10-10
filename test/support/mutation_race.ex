defmodule Renga.MutationRace do
  @moduledoc """
  Runs managed writes on independent connections and proves PostgreSQL
  lock contention before allowing the first transaction to commit.
  """

  import ExUnit.Assertions

  alias Ecto.Adapters.SQL.Sandbox
  alias Renga.Repo

  def race(held, competing) do
    # The caller keeps its fixture connection; two workers need their own.
    assert Repo.config()[:pool_size] >= 3
    parent = self()

    holder =
      concurrent(fn ->
        Repo.transaction(fn ->
          result = held.()
          [[backend]] = Repo.query!("SELECT pg_backend_pid()", []).rows
          send(parent, {:mutation_ready, self(), backend})

          receive do
            :release_mutation -> result
          after
            5_000 -> raise "held mutation was not released"
          end
        end)
      end)

    try do
      holder_pid = holder.pid
      assert_receive {:mutation_ready, ^holder_pid, holder_backend}, 1_000

      competitor =
        concurrent(fn ->
          [[backend]] = Repo.query!("SELECT pg_backend_pid()", []).rows
          send(parent, {:competitor_ready, self(), backend})
          competing.()
        end)

      try do
        competitor_pid = competitor.pid
        assert_receive {:competitor_ready, ^competitor_pid, competitor_backend}, 1_000

        assert Enum.any?(1..200, fn _ ->
                 [[blocked]] =
                   Repo.query!("SELECT $1 = ANY(pg_blocking_pids($2))", [
                     holder_backend,
                     competitor_backend
                   ]).rows

                 if !blocked, do: Process.sleep(10)
                 blocked
               end),
               "competing mutation never waited on the holder's database lock"

        send(holder.pid, :release_mutation)
        {:ok, held_result} = Task.await(holder, 5_000)
        {held_result, Task.await(competitor, 5_000)}
      after
        send(holder.pid, :release_mutation)
        Task.shutdown(competitor, 5_000)
      end
    after
      send(holder.pid, :release_mutation)
      Task.shutdown(holder, 5_000)
    end
  end

  defp concurrent(fun) do
    Task.async(fn ->
      :ok = Sandbox.checkout(Repo, sandbox: false)

      try do
        fun.()
      after
        Sandbox.checkin(Repo)
      end
    end)
  end
end
