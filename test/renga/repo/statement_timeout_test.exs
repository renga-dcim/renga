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
  defp backend_pid, do: Repo.query!("SELECT pg_backend_pid()").rows

  test "every connection has a baseline statement timeout, outside transactions too" do
    assert current_timeout() == [["1min"]]
  end

  test "the connection parameter cancels a standalone read" do
    config =
      Repo.config()
      |> Keyword.drop([:pool, :pool_size])
      |> Keyword.put(:parameters, statement_timeout: "100ms")

    connection = start_supervised!({Postgrex, config})

    {elapsed_us, {:error, error}} =
      :timer.tc(fn -> Postgrex.query(connection, "SELECT pg_sleep(2)", []) end)

    assert error.postgres.code == :query_canceled
    assert elapsed_us < 1_500_000
  end

  test "with_statement_timeout/2 applies to its own transaction only" do
    pid = backend_pid()
    assert {:ok, [["10s"]]} = Repo.with_statement_timeout(10_000, fn _ -> current_timeout() end)
    # Same connection afterwards, back at the baseline.
    assert backend_pid() == pid
    assert current_timeout() == [["1min"]]
  end

  test "passes a client timeout longer than the statement timeout" do
    assert {:ok, options} = Repo.with_statement_timeout(120_000, & &1)
    assert options[:timeout] > 120_000
  end

  test "a statement over the timeout is cancelled and the connection survives" do
    pid = backend_pid()

    error =
      assert_raise Postgrex.Error, fn ->
        Repo.with_statement_timeout(50, fn options ->
          Repo.query!("SELECT pg_sleep(1)", [], options)
        end)
      end

    assert error.postgres.code == :query_canceled
    assert backend_pid() == pid
    assert current_timeout() == [["1min"]]
  end

  test "an explicit rollback restores the baseline" do
    assert {:error, :stop} =
             Repo.with_statement_timeout(10_000, fn _ -> Repo.rollback(:stop) end)

    assert current_timeout() == [["1min"]]
  end

  test "nested in an outer transaction, it restores the outer setting on return" do
    Repo.transaction(fn ->
      assert {:ok, [["10s"]]} = Repo.with_statement_timeout(10_000, fn _ -> current_timeout() end)
      assert current_timeout() == [["1min"]]

      assert {:ok, {[["20s"]], [["10s"]]}} =
               Repo.with_statement_timeout(10_000, fn _ ->
                 {:ok, inner} =
                   Repo.with_statement_timeout(20_000, fn _ -> current_timeout() end)

                 {inner, current_timeout()}
               end)

      assert current_timeout() == [["1min"]]
    end)

    assert current_timeout() == [["1min"]]
  end

  test "a raise inside a nested override rolls back the outer transaction and the setting" do
    assert {:error, :rollback} =
             Repo.transaction(fn ->
               assert_raise RuntimeError, fn ->
                 Repo.with_statement_timeout(10_000, fn _ -> raise "boom" end)
               end
             end)

    assert current_timeout() == [["1min"]]
  end

  test "an override above the background maximum is refused before any query" do
    maximum = Repo.background_statement_timeout_ms()

    assert_raise ArgumentError, ~r/exceeds the background maximum/, fn ->
      Repo.with_statement_timeout(maximum + 1, fn _ -> flunk("ran") end)
    end
  end
end
