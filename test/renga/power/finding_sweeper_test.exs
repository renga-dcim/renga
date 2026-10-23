defmodule Renga.Power.FindingSweeperTest do
  use ExUnit.Case, async: true

  alias Renga.Power.FindingSweeper

  test "sweeps start on interval boundaries however long each one takes" do
    parent = self()
    interval = 200

    sweep = fn ->
      send(parent, {:swept, System.os_time(:millisecond)})
      # Most of an interval, which would push a sweep scheduled after the
      # last one finished into a later minute.
      Process.sleep(120)
    end

    start_supervised!({FindingSweeper, name: nil, interval: interval, sweep: sweep})

    starts =
      for _sweep <- 1..4 do
        assert_receive {:swept, at}, 1_000
        at
      end

    # Each starts just after a boundary, and none is skipped.
    assert Enum.all?(starts, &(rem(&1, interval) < 60)),
           inspect(Enum.map(starts, &rem(&1, interval)))

    assert starts
           |> Enum.chunk_every(2, 1, :discard)
           |> Enum.all?(fn [first, second] -> abs(second - first - interval) < 60 end)
  end
end
