defmodule Renga.Repo.StatementTimeoutTest do
  # Uses unsandboxed connections, where transaction-local settings end with
  # their transaction as in production.
  use ExUnit.Case, async: false

  alias Ecto.Adapters.SQL.Sandbox
  alias Renga.Repo

  setup do
    :ok = Sandbox.checkout(Repo, sandbox: false)
    on_exit(fn -> Sandbox.checkin(Repo) end)
  end

  defp current_timeout, do: Repo.query!("SHOW statement_timeout").rows

  test "every connection has a baseline statement timeout, outside transactions too" do
    assert current_timeout() == [["1min"]]
  end

  test "with_statement_timeout/2 applies to its own transaction only" do
    assert {:ok, [["10s"]]} = Repo.with_statement_timeout(10_000, &current_timeout/0)
    assert current_timeout() == [["1min"]]
  end

  test "a statement over the timeout is cancelled" do
    error =
      assert_raise Postgrex.Error, fn ->
        Repo.with_statement_timeout(50, fn -> Repo.query!("SELECT pg_sleep(1)") end)
      end

    assert error.postgres.code == :query_canceled
    assert current_timeout() == [["1min"]]
  end
end
