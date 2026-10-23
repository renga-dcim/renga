defmodule Renga.Telemetry.StoreConcurrencyTest do
  # Real transactions, outside the sandbox, so concurrent writes contend for
  # the same bucket rows as they would in production.
  use ExUnit.Case, async: false

  import Ecto.Query
  import Renga.InventoryFixtures

  alias Ecto.Adapters.SQL.Sandbox
  alias Renga.Accounts.Organization
  alias Renga.Accounts.Scope
  alias Renga.Repo
  alias Renga.Telemetry.Store

  @timeout 15_000
  @rounds 40

  test "overlapping writes of different sizes merge without deadlocking" do
    :ok = Sandbox.checkout(Repo, sandbox: false)
    organization = organization_fixture()
    scope = %Scope{organization_id: organization.id}
    at = DateTime.add(Store.floor_to(Renga.Time.utc_now_ms(), 300), -3_600, :second)

    try do
      # Groups of more and fewer than 32 buckets enumerate in different
      # orders, so unordered upserts lock shared rows in opposite orders.
      wide = for n <- 1..48, do: %{series: "s#{n}", at: at, value: 1.0}
      narrow = for n <- 1..24, do: %{series: "s#{n}", at: at, value: 2.0}

      for _round <- 1..@rounds do
        parent = self()
        tasks = Enum.map([wide, narrow], &writer(parent, scope, &1))

        pids =
          for _task <- tasks do
            assert_receive {:ready, pid}, @timeout
            pid
          end

        Enum.each(pids, &send(&1, :go))
        assert Enum.map(tasks, &Task.await(&1, @timeout)) == [:ok, :ok]
      end

      {:ok, buckets} = Store.range(scope, ["s1", "s30"], at, DateTime.add(at, 300), 300)
      assert [%{count: count, average: average}] = buckets["s1"]
      assert count == 2 * @rounds
      assert_in_delta average, 1.5, 1.0e-9
      assert [%{count: count}] = buckets["s30"]
      assert count == @rounds
    after
      Repo.delete_all(
        from(bucket in "telemetry_buckets",
          where: bucket.organization_id == type(^organization.id, :binary_id)
        )
      )

      Repo.delete_all(where(Organization, [org], org.id == ^organization.id))
      Sandbox.checkin(Repo)
    end
  end

  defp writer(parent, scope, samples) do
    Task.async(fn ->
      :ok = Sandbox.checkout(Repo, sandbox: false)
      send(parent, {:ready, self()})

      try do
        receive do
          :go ->
            try do
              Store.write(scope, samples)
            rescue
              error -> {:error, Exception.message(error)}
            end
        after
          @timeout -> raise "timed out waiting to write"
        end
      after
        Sandbox.checkin(Repo)
      end
    end)
  end
end
