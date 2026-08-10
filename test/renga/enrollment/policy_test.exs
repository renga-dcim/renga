defmodule Renga.Enrollment.PolicyTest do
  use ExUnit.Case, async: true
  alias Renga.Enrollment.{Canonical, Policy}

  defp leaf(id, path, op, value),
    do: %{"id" => id, "attribute" => path, "operator" => op, "value" => value}

  test "typed trees support operators, outputs, and grant narrowing" do
    rule = %{
      "all" => [
        leaf("prefix", ["verified", "issuer"], "prefix", "manual:"),
        leaf("integer", ["server", "count"], "int_gte", 2),
        leaf("semver", ["verified", "version"], "semver_gt", "1.9.9"),
        leaf("member", ["verified", "region"], "in", ["us", "eu"]),
        %{
          "any" => [
            leaf("a", ["verified", "name"], "eq", "agent"),
            leaf("b", ["verified", "name"], "eq", "other")
          ]
        }
      ]
    }

    policy = %{
      "rule" => rule,
      "assignments" => %{"site" => "dc1"},
      "grants" => ["observe", "admin"]
    }

    attrs = %{
      "verified" => %{
        "issuer" => "manual:prod",
        "version" => "1.10.0",
        "region" => "eu",
        "name" => "agent"
      },
      "server" => %{"count" => 2}
    }

    assert {:allow, result} = Policy.evaluate(policy, attrs, ["observe", "untrusted"])
    assert result.assignments == %{"site" => "dc1"}
    assert result.grants == ["observe"]
  end

  test "missing, unknown, untrusted roots, bad semver, and type errors fail closed" do
    cases = [
      {leaf("missing", ["verified", "absent"], "eq", "x"), "missing_attribute"},
      {leaf("unknown", ["verified", "x"], "magic", "x"), "unknown_operator"},
      {leaf("typed", ["verified", "x"], "eq", 1), "type_error"},
      {leaf("semver", ["verified", "x"], "semver_gt", "1.0.0"), "type_error"},
      {leaf("root", ["submitted", "x"], "eq", "x"), "invalid_condition"}
    ]

    for {condition, reason} <- cases do
      assert {:deny, %{reason: ^reason, condition_ids: [_]}} =
               Policy.evaluate(%{"rule" => condition}, %{"verified" => %{"x" => "latest"}})
    end
  end

  test "a condition with an arbitrary fourth key cannot substitute a nil value" do
    malformed = %{
      "id" => "malformed",
      "attribute" => ["verified", "optional"],
      "operator" => "eq",
      "typo" => nil
    }

    assert {:deny, %{reason: "invalid_condition", condition_ids: ["malformed"]}} =
             Policy.evaluate(%{"rule" => malformed}, %{"verified" => %{"optional" => nil}})
  end

  test "existence and finite-number comparison are typed" do
    assert {:allow, _} =
             Policy.evaluate(%{"rule" => leaf("exists", ["verified", "x"], "exists", true)}, %{
               "verified" => %{"x" => nil}
             })

    assert {:allow, _} =
             Policy.evaluate(%{"rule" => leaf("number", ["verified", "x"], "number_lt", 2.0)}, %{
               "verified" => %{"x" => 1.5}
             })

    assert {:deny, %{reason: "condition_not_met"}} =
             Policy.evaluate(%{"rule" => leaf("false", ["verified", "x"], "eq", "no")}, %{
               "verified" => %{"x" => "yes"}
             })
  end

  test "depth, node, and string bounds deny" do
    assert {:deny, %{reason: "invalid_policy"}} =
             Policy.evaluate(
               %{"rule" => leaf("large", ["verified", "x"], "eq", String.duplicate("x", 1025))},
               %{}
             )

    nodes = Enum.map(1..129, &leaf(Integer.to_string(&1), ["verified", "x"], "exists", false))

    assert {:deny, %{reason: "invalid_policy"}} =
             Policy.evaluate(%{"rule" => %{"all" => nodes}}, %{})

    deep =
      Enum.reduce(1..10, leaf("x", ["verified", "x"], "exists", false), fn _, node ->
        %{"all" => [node]}
      end)

    assert {:deny, %{reason: "invalid_policy"}} = Policy.evaluate(%{"rule" => deep}, %{})
  end

  test "canonical encoding is deterministic and typed" do
    assert Canonical.encode(%{"b" => [1, true], "a" => "x"}) ==
             Canonical.encode(%{"a" => "x", "b" => [1, true]})

    refute Canonical.encode(1) == Canonical.encode("1")
    assert_raise FunctionClauseError, fn -> Canonical.encode(%{atom: "not JSON"}) end
  end
end
