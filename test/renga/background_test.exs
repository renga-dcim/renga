defmodule Renga.BackgroundTest do
  use Renga.DataCase, async: false
  import Renga.InventoryFixtures
  alias Renga.Accounts.Organization
  alias Renga.Background

  test "the persisted cursor moves past failures and survives a new scheduler caller" do
    ids = Enum.sort(for _ <- 1..3, do: organization_fixture().id)
    ready = from org in Organization, where: org.id in ^ids, select: %{organization_id: org.id}
    worker = "test-#{Ecto.UUID.generate()}"
    parent = self()

    # A single batch consumes the wall budget, so each invocation has to
    # continue from the durable cursor rather than starting at the first ID.
    for expected <- ids do
      Background.run(
        worker,
        ready,
        fn id ->
          send(parent, {:visited, id})
          Process.sleep(100)
        end,
        budget_ms: 10,
        batch_timeout_ms: 100
      )

      assert_receive {:visited, ^expected}
    end

    [first | _] = ids

    Background.run(
      worker,
      ready,
      fn id ->
        send(parent, {:visited, id})
        Process.sleep(100)
      end,
      budget_ms: 10,
      batch_timeout_ms: 100
    )

    assert_receive {:visited, ^first}
  end

  test "a failed organization does not stop a later ready organization in the round" do
    [bad, good] = Enum.sort(for _ <- 1..2, do: organization_fixture().id)

    ready =
      from org in Organization, where: org.id in ^[bad, good], select: %{organization_id: org.id}

    parent = self()

    results =
      Background.run("test-#{Ecto.UUID.generate()}", ready, fn
        ^bad ->
          raise "injected background failure"

        ^good ->
          send(parent, :healthy_batch)
          :healthy
      end)

    assert_receive :healthy_batch
    assert [{:exit, _}, {:ok, :healthy}] = results
  end
end
