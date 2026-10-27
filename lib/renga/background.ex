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
    lane =
      case worker do
        "job_sweep" -> :job_background
        "export_generation" -> :export_background
        _other -> :background
      end

    case Renga.IntakeCapacity.acquire(lane, 1) do
      {:ok, permit} ->
        try do
          deadline = System.monotonic_time(:millisecond) + Keyword.get(options, :budget_ms, 1_000)
          rotate(worker, ready_query, batch, deadline, MapSet.new(), options, [])
        after
          Renga.IntakeCapacity.release(permit)
        end

      :full ->
        []
    end
  end

  defp rotate(worker, query, batch, deadline, visited, options, results) do
    remaining = deadline - System.monotonic_time(:millisecond)
    max_batches = Keyword.get(options, :max_batches)

    if remaining <= 0 or (is_integer(max_batches) and MapSet.size(visited) >= max_batches) do
      Enum.reverse(results)
    else
      case next(worker, query) do
        nil ->
          Enum.reverse(results)

        organization_id ->
          if MapSet.member?(visited, organization_id) do
            Enum.reverse(results)
          else
            timeout = min(remaining, Keyword.get(options, :batch_timeout_ms, 250))

            task =
              Task.Supervisor.async_nolink(Renga.Background.Tasks, fn ->
                :telemetry.execute(
                  [:renga, :background, :batch, :start],
                  %{monotonic_time: System.monotonic_time()},
                  %{worker: worker, organization_id: organization_id}
                )

                batch.(organization_id)
              end)

            result = Task.yield(task, timeout) || Task.shutdown(task, :brutal_kill)

            unless match?({:ok, _}, result),
              do:
                Logger.warning(
                  "Background #{worker} batch failed for #{organization_id}: #{inspect(result)}"
                )

            rotate(
              worker,
              query,
              batch,
              deadline,
              MapSet.put(visited, organization_id),
              options,
              [result | results]
            )
          end
      end
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
