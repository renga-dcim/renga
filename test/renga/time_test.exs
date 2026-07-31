defmodule Renga.TimeTest do
  use ExUnit.Case, async: true

  describe "utc_now_ms/0" do
    test "returns an Ecto-compatible millisecond-aligned timestamp" do
      %DateTime{microsecond: {microsecond, precision}} = Renga.Time.utc_now_ms()

      assert precision == 6
      assert rem(microsecond, 1_000) == 0
    end
  end

  describe "from_unix_ms!/1" do
    test "preserves the millisecond instant with Ecto-compatible precision" do
      timestamp = Renga.Time.from_unix_ms!(1_775_000_000_123)

      assert timestamp == ~U[2026-03-31 23:33:20.123000Z]
      assert timestamp.microsecond == {123_000, 6}
    end
  end
end
