# credo:disable-for-this-file Credo.Check.Refactor.CyclomaticComplexity
defmodule Renga.Enrollment.Policy do
  @moduledoc """
  Bounded, fail-closed evaluator for enrollment policy JSON.

  A document is `%{"rule" => node, "assignments" => map, "grants" => [string]}`.
  Nodes are exactly `%{"all" => [node]}`, `%{"any" => [node]}`, or condition
  leaves `%{"id" => string, "attribute" => ["verified" | "server", ...],
  "operator" => operator, "value" => value}`. Operators are `eq`, `in`,
  `exists`, `prefix`, `int_gt/int_gte/int_lt/int_lte`,
  `number_gt/number_gte/number_lt/number_lte`, and
  `semver_gt/semver_gte/semver_lt/semver_lte`. Values are never coerced.
  """
  @max_depth 8
  @max_nodes 128
  @max_string 1024
  @max_list 128

  def evaluate(document, attributes, requested \\ []) do
    with :ok <- bounded?(document),
         %{"rule" => rule} <- document,
         :ok <- valid_outputs(document),
         {:ok, passed, ids} <- eval(rule, attributes, 0) do
      if passed do
        assignments = Map.get(document, "assignments", %{})
        grants = intersection(Map.get(document, "grants", []), requested)

        {:allow,
         %{reason: "policy_allow", condition_ids: ids, assignments: assignments, grants: grants}}
      else
        {:deny, %{reason: "condition_not_met", condition_ids: ids}}
      end
    else
      {:error, reason, ids} -> {:deny, %{reason: reason, condition_ids: ids}}
      _ -> {:deny, %{reason: "invalid_policy", condition_ids: []}}
    end
  rescue
    _ -> {:deny, %{reason: "invalid_policy", condition_ids: []}}
  end

  defp bounded?(term), do: walk(term, 0, 0) |> elem(0)

  defp valid_outputs(document) do
    assignments = Map.get(document, "assignments", %{})
    grants = Map.get(document, "grants", [])

    if is_map(assignments) and is_list(grants) and
         Enum.all?(grants, &(is_binary(&1) and &1 != "")),
       do: :ok,
       else: :error
  end

  defp walk(_, depth, count) when depth > @max_depth or count >= @max_nodes, do: {:error, count}

  defp walk(value, _, count) when is_binary(value),
    do: {if(byte_size(value) <= @max_string, do: :ok, else: :error), count + 1}

  defp walk(value, depth, count) when is_list(value) and length(value) <= @max_list,
    do:
      Enum.reduce_while(value, {:ok, count + 1}, fn x, {:ok, n} ->
        case walk(x, depth + 1, n) do
          {:ok, n2} -> {:cont, {:ok, n2}}
          error -> {:halt, error}
        end
      end)

  defp walk(value, depth, count) when is_map(value) and map_size(value) <= @max_list do
    Enum.reduce_while(value, {:ok, count + 1}, fn
      {key, item}, {:ok, n} when is_binary(key) ->
        with {:ok, n2} <- walk(key, depth + 1, n),
             {:ok, n3} <- walk(item, depth + 1, n2) do
          {:cont, {:ok, n3}}
        else
          error -> {:halt, error}
        end

      _, state ->
        {:halt, {:error, elem(state, 1)}}
    end)
  end

  defp walk(value, _, count) when is_nil(value) or is_boolean(value) or is_integer(value),
    do: {:ok, count + 1}

  defp walk(value, _, count) when is_float(value),
    do: {if(finite?(value), do: :ok, else: :error), count + 1}

  defp walk(_, _, count), do: {:error, count}

  defp eval(%{"all" => nodes} = node, attrs, depth)
       when map_size(node) == 1 and is_list(nodes) and nodes != [],
       do: combine(nodes, attrs, depth, :all)

  defp eval(%{"any" => nodes} = node, attrs, depth)
       when map_size(node) == 1 and is_list(nodes) and nodes != [],
       do: combine(nodes, attrs, depth, :any)

  defp eval(
         %{
           "id" => id,
           "attribute" => [root | _] = path,
           "operator" => op,
           "value" => expected
         } = leaf,
         attrs,
         _
       )
       when map_size(leaf) == 4 and is_binary(id) and root in ["verified", "server"] do
    case fetch(attrs, path) do
      :missing ->
        if op == "exists",
          do: {:ok, expected == false, [id]},
          else: {:error, "missing_attribute", [id]}

      {:ok, actual} ->
        compare(op, actual, expected, id)
    end
  end

  defp eval(%{"id" => id}, _, _),
    do: {:error, "invalid_condition", if(is_binary(id), do: [id], else: [])}

  defp eval(_, _, _), do: {:error, "invalid_policy", []}

  defp combine(nodes, attrs, depth, mode) do
    results = Enum.map(nodes, &eval(&1, attrs, depth + 1))

    case Enum.find(results, &match?({:error, _, _}, &1)) do
      nil ->
        ids = Enum.flat_map(results, fn {:ok, _, ids} -> ids end)
        values = Enum.map(results, fn {:ok, value, _} -> value end)
        {:ok, if(mode == :all, do: Enum.all?(values), else: Enum.any?(values)), ids}

      error ->
        error
    end
  end

  defp fetch(value, []), do: {:ok, value}

  defp fetch(map, [key | rest]) when is_map(map) and is_binary(key),
    do: if(Map.has_key?(map, key), do: fetch(Map.fetch!(map, key), rest), else: :missing)

  defp fetch(_, _), do: :missing

  defp compare("exists", _, expected, id) when is_boolean(expected), do: {:ok, expected, [id]}

  defp compare("eq", actual, expected, id) do
    if same_type?(actual, expected),
      do: {:ok, actual == expected, [id]},
      else: {:error, "type_error", [id]}
  end

  defp compare("in", actual, expected, id) when is_list(expected),
    do:
      if(Enum.all?(expected, &same_type?(actual, &1)),
        do: {:ok, actual in expected, [id]},
        else: {:error, "type_error", [id]}
      )

  defp compare("prefix", actual, expected, id) when is_binary(actual) and is_binary(expected),
    do: {:ok, String.starts_with?(actual, expected), [id]}

  defp compare("int_" <> op, actual, expected, id)
       when is_integer(actual) and is_integer(expected), do: ordered(op, actual, expected, id)

  defp compare("number_" <> op, actual, expected, id)
       when is_number(actual) and is_number(expected),
       do:
         if(finite?(actual) and finite?(expected),
           do: ordered(op, actual, expected, id),
           else: {:error, "type_error", [id]}
         )

  defp compare("semver_" <> op, actual, expected, id)
       when is_binary(actual) and is_binary(expected),
       do: semver_ordered(op, actual, expected, id)

  defp compare(op, _, _, id)
       when op in ~w(eq in exists prefix int_gt int_gte int_lt int_lte number_gt number_gte number_lt number_lte semver_gt semver_gte semver_lt semver_lte),
       do: {:error, "type_error", [id]}

  defp compare(_, _, _, id), do: {:error, "unknown_operator", [id]}

  defp ordered("gt", a, b, id), do: {:ok, a > b, [id]}
  defp ordered("gte", a, b, id), do: {:ok, a >= b, [id]}
  defp ordered("lt", a, b, id), do: {:ok, a < b, [id]}
  defp ordered("lte", a, b, id), do: {:ok, a <= b, [id]}
  defp ordered(_, _, _, id), do: {:error, "unknown_operator", [id]}

  defp semver_ordered(op, actual, expected, id) do
    with {:ok, actual_version} <- Version.parse(actual),
         {:ok, expected_version} <- Version.parse(expected) do
      comparison = Version.compare(actual_version, expected_version)

      case op do
        "gt" -> {:ok, comparison == :gt, [id]}
        "gte" -> {:ok, comparison in [:gt, :eq], [id]}
        "lt" -> {:ok, comparison == :lt, [id]}
        "lte" -> {:ok, comparison in [:lt, :eq], [id]}
        _ -> {:error, "unknown_operator", [id]}
      end
    else
      _ -> {:error, "type_error", [id]}
    end
  end

  defp same_type?(a, b),
    do:
      (is_binary(a) and is_binary(b)) or (is_integer(a) and is_integer(b)) or
        (is_float(a) and is_float(b)) or (is_boolean(a) and is_boolean(b)) or
        (is_nil(a) and is_nil(b))

  defp intersection(policy, requested) when is_list(policy) and is_list(requested),
    do: policy |> Enum.filter(&(is_binary(&1) and &1 in requested)) |> Enum.uniq() |> Enum.sort()

  defp intersection(_, _), do: []
  defp finite?(n) when is_integer(n), do: true
  defp finite?(n) when is_float(n), do: n < 1.0e308 and n > -1.0e308
end
