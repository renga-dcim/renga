defmodule Renga.Repo do
  @moduledoc """
  Database boundary for Renga's single PostgreSQL-backed tenancy model.
  """

  use Ecto.Repo,
    otp_app: :renga,
    adapter: Ecto.Adapters.Postgres

  # Head room for the client-side query timeout over the server-side one, so
  # PostgreSQL cancels a slow statement first and the connection survives
  # instead of being dropped by DBConnection.
  @client_timeout_margin_ms :timer.seconds(5)

  @doc """
  Runs `fun` in a transaction whose statements may each run for up to
  `timeout_ms` instead of the connection's baseline `statement_timeout`
  (RFD 21), and returns the transaction's result.

  The transaction itself gets a client-side deadline of `timeout_ms` plus a
  margin, and `fun` receives query options carrying the same `:timeout`;
  pass them to every query inside, since Ecto's default client timeout (15
  seconds) would otherwise end a longer statement first. That deadline
  covers the whole transaction, not each statement, so keep the work inside
  to one bounded batch. Nested in an outer transaction, the outer deadline
  still applies; DBConnection cannot extend it.

  `timeout_ms` may not exceed `background_statement_timeout_ms/0`. Only
  approved background work uses this, never request handling: the baseline
  keeps one organization's slow query from holding a connection others need.
  `statement_timeout` bounds each statement, not the whole job, so callers
  still need their own wall-clock budget and a resumable boundary, such as
  working in batches.

  The override is transaction-local, so it ends with the transaction and
  never reaches the connection's next borrower. Nested in an outer
  transaction, it restores the outer setting when `fun` returns; a raise or
  rollback inside marks the outer transaction for rollback (Ecto nests
  without savepoints), which discards the setting with it.
  """
  def with_statement_timeout(timeout_ms, fun)
      when is_integer(timeout_ms) and timeout_ms > 0 and is_function(fun, 1) do
    maximum = background_statement_timeout_ms()

    if timeout_ms > maximum do
      raise ArgumentError,
            "statement timeout #{timeout_ms}ms exceeds the background maximum of #{maximum}ms"
    end

    options = [timeout: timeout_ms + @client_timeout_margin_ms]

    transaction(
      fn ->
        %{rows: [[previous]]} = query!("SHOW statement_timeout", [], options)
        # SET LOCAL takes no bind parameters; set_config is its parameterized form.
        set_local_statement_timeout("#{timeout_ms}ms", options)
        result = fun.(options)
        set_local_statement_timeout(previous, options)
        result
      end,
      options
    )
  end

  defp set_local_statement_timeout(value, options),
    do: query!("SELECT set_config('statement_timeout', $1, true)", [value], options)

  @doc """
  The longer per-statement timeout approved background work may use, in
  milliseconds.
  """
  def background_statement_timeout_ms,
    do: Application.get_env(:renga, :background_statement_timeout_ms, :timer.minutes(5))
end
