defmodule Renga.JSONTest do
  use ExUnit.Case, async: true

  alias Renga.Catalog.JSONB

  test "decodes and encodes PostgreSQL-scale fractional numbers exactly" do
    for number <- [
          "0.12345678901234567890123456789012345",
          "1e10000",
          "1e-10000"
        ] do
      assert {:ok, %{"number" => %Decimal{} = decimal}} =
               Renga.JSON.decode(~s({"number":#{number}}))

      encoded = Renga.JSON.encode!(%{"number" => decimal})
      refute encoded =~ ~s("#{number}")
      assert {:ok, %{"number" => ^decimal}} = Renga.JSON.decode(encoded)
    end
  end

  test "JSONB validation enforces PostgreSQL numeric boundaries without Decimal context rounding" do
    assert :ok = JSONB.validate(%Decimal{sign: 1, coef: 1, exp: 131_071})
    assert {:error, _message} = JSONB.validate(%Decimal{sign: 1, coef: 1, exp: 131_072})
    assert :ok = JSONB.validate(%Decimal{sign: 1, coef: 1, exp: -16_383})
    assert {:error, _message} = JSONB.validate(%Decimal{sign: 1, coef: 1, exp: -16_384})

    coefficient = String.to_integer("1" <> String.duplicate("2", 40))
    assert :ok = JSONB.validate(%Decimal{sign: 1, coef: coefficient, exp: -40})
  end

  test "web JSON keeps native request floats and emits Decimal values as numbers" do
    assert {:ok, %{"number" => number}} = RengaWeb.JSON.decode(~s({"number":1.5}))
    assert is_float(number)
    assert RengaWeb.JSON.encode!(%{"number" => Decimal.new("1.50")}) == ~s({"number":1.50})
  end
end
