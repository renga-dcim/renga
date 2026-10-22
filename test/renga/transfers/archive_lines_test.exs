defmodule Renga.Transfers.Archive.LinesTest do
  use ExUnit.Case, async: true

  alias Renga.Transfers.Archive.Lines

  test "joins lines split across chunks" do
    assert split(["ab", "c\nd", "e\n\nf", "g\n"], :infinity) ==
             [{:line, "abc"}, {:line, "de"}, {:line, ""}, {:line, "fg"}]
  end

  test "reports an unterminated last line" do
    assert split(["a\nb"], :infinity) == [{:line, "a"}, :unterminated]
    assert split([], :infinity) == []
  end

  test "drops a line over the limit and resumes after it" do
    assert split(["12", "345", "6\nok\n1234567"], 4) ==
             [{:too_long, 6}, {:line, "ok"}, :unterminated]

    assert split(["1234\n12345\n"], 4) == [{:line, "1234"}, {:too_long, 5}]
  end

  defp split(chunks, max), do: chunks |> Lines.stream(max) |> Enum.to_list()
end
