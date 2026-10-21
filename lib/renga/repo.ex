defmodule Renga.Repo do
  @moduledoc """
  Database boundary for Renga's single PostgreSQL-backed tenancy model.
  """

  use Ecto.Repo,
    otp_app: :renga,
    adapter: Ecto.Adapters.Postgres

  @doc """
  Runs `fun` in a transaction whose statements may each run for up to
  `timeout_ms` instead of the connection's baseline `statement_timeout`
  (RFD 21), and returns the transaction's result.

  Only approved background work uses this, never request handling: the
  baseline keeps one organization's slow query from holding a connection
  others need. `statement_timeout` bounds each statement, not the whole
  job, so callers still need their own wall-clock budget and a resumable
  boundary, such as working in batches.
  """
  def with_statement_timeout(timeout_ms, fun)
      when is_integer(timeout_ms) and timeout_ms >= 0 and is_function(fun, 0) do
    transaction(fn ->
      # SET LOCAL takes no bind parameters; set_config is its parameterized form.
      query!("SELECT set_config('statement_timeout', $1, true)", ["#{timeout_ms}ms"])
      fun.()
    end)
  end

  @doc """
  The longer per-statement timeout approved background work may use, in
  milliseconds.
  """
  def background_statement_timeout_ms,
    do: Application.get_env(:renga, :background_statement_timeout_ms, :timer.minutes(5))
end
