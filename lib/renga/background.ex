defmodule Renga.Background do
  @moduledoc """
  Persistent round-robin organization rotation for bounded background batches.
  The cursor commits before work starts: failure or restart skips the failed
  organization for the round, rather than pinning everyone behind it. No
  domain locks are held while advancing it. A batch has a wall-clock deadline
  in addition to PostgreSQL's per-statement deadline.
  """
  require Logger
  import Ecto.Query
  alias Renga.Repo

  def run(worker, ready_query, batch, options \\ []) do
    caller = self()
    deadline = System.monotonic_time(:millisecond) + Keyword.get(options, :budget_ms, 1_000)

    # This coordinator survives its caller long enough to cancel active work.
    # Each executing child owns its reserve, so even an exit-trapping batch
    # cannot lose its permit merely because the coordinator dies.
    Task.Supervisor.async_nolink(Renga.Background.Tasks, fn ->
      Process.flag(:trap_exit, true)
      caller_ref = Process.monitor(caller)

      try do
        rotate(
          %{
            worker: worker,
            query: ready_query,
            batch: batch,
            deadline: deadline,
            caller_ref: caller_ref,
            visited: MapSet.new(),
            options: options
          },
          []
        )
      catch
        :caller_down -> []
      after
        Process.demonitor(caller_ref, [:flush])
      end
    end)
    |> Task.await(:infinity)
  end

  defp rotate(state, results) do
    remaining = state.deadline - System.monotonic_time(:millisecond)
    max_batches = Keyword.get(state.options, :max_batches)

    if remaining <= 0 or (is_integer(max_batches) and MapSet.size(state.visited) >= max_batches) do
      Enum.reverse(results)
    else
      case bounded_task(
             state.worker,
             fn -> next(state.worker, state.query) end,
             remaining,
             state.caller_ref
           ) do
        {:ok, organization_id} when not is_nil(organization_id) ->
          visit(state, organization_id, results)

        _selection_failed_or_empty ->
          Enum.reverse(results)
      end
    end
  end

  defp visit(state, organization_id, results) do
    remaining = state.deadline - System.monotonic_time(:millisecond)

    if remaining <= 0 or MapSet.member?(state.visited, organization_id) do
      Enum.reverse(results)
    else
      timeout = min(remaining, Keyword.get(state.options, :batch_timeout_ms, 250))

      result =
        bounded_task(
          state.worker,
          fn ->
            :telemetry.execute(
              [:renga, :background, :batch, :start],
              %{monotonic_time: System.monotonic_time()},
              %{worker: state.worker, organization_id: organization_id}
            )

            state.batch.(organization_id)
          end,
          timeout,
          state.caller_ref
        )

      unless match?({:ok, _}, result),
        do:
          Logger.warning(
            "Background #{state.worker} batch failed for #{organization_id}: #{inspect(result)}"
          )

      rotate(%{state | visited: MapSet.put(state.visited, organization_id)}, [result | results])
    end
  end

  defp bounded_task(worker, fun, timeout, caller_ref) do
    lane =
      case worker do
        "job_sweep" -> :job_background
        "export_generation" -> :export_background
        _ -> :background
      end

    task =
      Task.Supervisor.async(Renga.Background.Tasks, fn ->
        case Renga.IntakeCapacity.acquire(lane, 1) do
          {:ok, permit} ->
            try do
              {:ok, fun.()}
            after
              Renga.IntakeCapacity.release(permit)
            end

          :full ->
            :full
        end
      end)

    receive do
      {ref, result} when ref == task.ref ->
        Process.demonitor(ref, [:flush])
        result

      {:DOWN, ref, :process, _pid, reason} when ref == task.ref ->
        {:exit, reason}

      {:DOWN, ^caller_ref, :process, _pid, _reason} ->
        Task.shutdown(task, 100)
        throw(:caller_down)
    after
      max(timeout, 0) ->
        Task.shutdown(task, 100)
        nil
    end
  end

  defp next(worker, query) do
    {:ok, next} =
      Repo.with_statement_timeout(200, fn _options ->
        Repo.query!("INSERT INTO background_cursors(worker) VALUES ($1) ON CONFLICT DO NOTHING", [
          worker
        ])

        %{rows: [[cursor]]} =
          Repo.query!(
            "SELECT last_organization_id FROM background_cursors WHERE worker = $1 FOR UPDATE",
            [worker]
          )

        ready =
          from entry in subquery(query),
            order_by: entry.organization_id,
            limit: 1,
            select: entry.organization_id

        next =
          if cursor do
            previous = Ecto.UUID.load!(cursor)
            Repo.one(from entry in ready, where: entry.organization_id > ^previous)
          end

        next = next || Repo.one(ready)

        if next do
          Repo.query!(
            "UPDATE background_cursors SET last_organization_id = $2 WHERE worker = $1",
            [
              worker,
              Ecto.UUID.dump!(next)
            ]
          )
        end

        next
      end)

    next
  end
end
