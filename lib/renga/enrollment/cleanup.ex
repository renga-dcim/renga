defmodule Renga.Enrollment.Cleanup do
  @moduledoc "Bounded periodic removal of expired enrollment operational records."

  use GenServer

  alias Renga.Repo

  @default_options [interval: :timer.minutes(5), batch_size: 500, max_batches_per_tick: 4]

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "Runs one deterministic, strictly bounded cleanup tick."
  def cleanup_once do
    options = options()

    %{
      replays: delete_batches(:replays, options),
      challenges: delete_batches(:challenges, options)
    }
  end

  @impl true
  def init(_opts) do
    schedule(options()[:interval])
    {:ok, %{}}
  end

  @impl true
  def handle_info(:cleanup, state) do
    cleanup_once()
    schedule(options()[:interval])
    {:noreply, state}
  end

  defp delete_batches(kind, options) do
    # Each query and tick has a hard ceiling so stale high-volume data cannot
    # monopolize the Repo pool or create an unbounded write transaction.
    # TODO: Consider archiving historical enrollment/terminal audit data to ClickHouse.
    Enum.reduce_while(1..options[:max_batches_per_tick], 0, fn _, total ->
      deleted = delete_batch(kind, options[:batch_size])
      next_total = total + deleted

      if deleted < options[:batch_size], do: {:halt, next_total}, else: {:cont, next_total}
    end)
  end

  defp delete_batch(:replays, batch_size) do
    # TODO: Consider archiving expired replay history to ClickHouse; active
    # replay protection must remain in the transactional database until expiry.
    delete_expired("enrollment_replays", "expires_at <= $1", batch_size)
  end

  defp delete_batch(:challenges, batch_size) do
    delete_expired(
      "enrollment_challenges",
      """
      expires_at <= $1 AND status = 'open' AND submission_digest IS NULL
      AND NOT EXISTS (
        SELECT 1 FROM enrollment_attempts
        WHERE enrollment_attempts.organization_id = enrollment_challenges.organization_id
          AND enrollment_attempts.enrollment_challenge_id = enrollment_challenges.id
      )
      """,
      batch_size
    )
  end

  defp delete_expired(table, predicate, batch_size) do
    now = Renga.Time.utc_now_ms()

    result =
      Repo.query!(
        """
        DELETE FROM #{table}
        WHERE id IN (
          SELECT id FROM #{table}
          WHERE #{predicate}
          ORDER BY expires_at
          FOR UPDATE SKIP LOCKED
          LIMIT $2
        )
        """,
        [now, batch_size]
      )

    result.num_rows
  end

  defp options do
    @default_options
    |> Keyword.merge(Application.get_env(:renga, __MODULE__, []))
    |> Map.new()
  end

  defp schedule(interval), do: Process.send_after(self(), :cleanup, interval)
end
