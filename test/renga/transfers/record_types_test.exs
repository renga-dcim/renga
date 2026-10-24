defmodule Renga.Transfers.RecordTypesTest do
  @moduledoc """
  Holds the export's record types to the database schema, so a migration
  cannot add organization data, or a credential, that the export silently
  includes or drops.
  """

  use Renga.DataCase, async: true

  alias Renga.Transfers.RecordTypes

  setup do
    %{rows: columns} =
      Repo.query!("""
      SELECT c.table_name, c.column_name
      FROM information_schema.columns AS c
      JOIN information_schema.tables AS t USING (table_schema, table_name)
      WHERE c.table_schema = current_schema() AND t.table_type = 'BASE TABLE'
      """)

    columns = Enum.group_by(columns, &hd/1, &List.last/1)

    %{rows: foreign_keys} =
      Repo.query!("""
      SELECT c.conrelid::regclass::text, c.confrelid::regclass::text,
             (SELECT array_agg(a.attname::text ORDER BY k.n)
              FROM unnest(c.conkey) WITH ORDINALITY AS k(attnum, n)
              JOIN pg_attribute AS a ON a.attrelid = c.conrelid AND a.attnum = k.attnum)
      FROM pg_constraint AS c
      WHERE c.contype = 'f'
      """)

    organization_tables =
      for {table, table_columns} <- columns, "organization_id" in table_columns, do: table

    %{
      columns: columns,
      foreign_keys:
        Enum.map(foreign_keys, fn [from, to, [field | _rest]] -> {from, to, field} end),
      organization_tables: organization_tables
    }
  end

  test "every organization-owned table is exported or excluded with a reason", context do
    exported = MapSet.new(RecordTypes.all(), & &1.name)
    excluded = MapSet.new(Map.keys(RecordTypes.excluded_tables()))

    assert MapSet.disjoint?(exported, excluded)

    assert Enum.sort(context.organization_tables) ==
             Enum.sort(MapSet.to_list(MapSet.union(exported, excluded)))
  end

  test "every column of an exported table is exported or excluded with a reason", context do
    for type <- RecordTypes.all() do
      excluded = RecordTypes.excluded_fields() |> Map.get(type.name, %{}) |> Map.keys()
      columns = Map.fetch!(context.columns, type.name)

      assert Enum.sort(columns) == Enum.sort(["organization_id" | type.fields ++ excluded]),
             "#{type.name}: classify every column as exported or excluded"

      assert type.fields == Enum.uniq(type.fields)
      assert type.fields -- columns == []
    end

    assert Enum.sort(Map.fetch!(context.columns, "organizations")) ==
             Enum.sort(~w(id status) ++ RecordTypes.organization_fields())
  end

  test "no exported field holds a credential" do
    for type <- RecordTypes.all(), field <- type.fields do
      refute field =~ ~r/(hash|token|secret|password|nonce|ciphertext)/,
             "#{type.name}.#{field} looks like a credential"
    end
  end

  test "every field naming a person is a principal field", context do
    exported = MapSet.new(RecordTypes.all(), & &1.name)

    referencing_users =
      for {from, "users", field} <- context.foreign_keys, from in exported, do: {from, field}

    principal_fields =
      for type <- RecordTypes.all(), {field, condition} <- type.principal_fields do
        if is_nil(condition), do: assert({type.name, field} in referencing_users)
        {type.name, field}
      end

    assert Enum.sort(referencing_users) -- principal_fields == []
    assert {"job_events", "actor_id"} in principal_fields
  end

  test "record types refer only to earlier record types, except through deferred fields",
       context do
    order = RecordTypes.all() |> Enum.with_index() |> Map.new(fn {type, i} -> {type.name, i} end)

    deferred =
      for type <- RecordTypes.all(), field <- type.deferred_fields, do: {type.name, field}

    for {from, to, field} <- context.foreign_keys,
        Map.has_key?(order, from),
        Map.has_key?(order, to),
        from != to,
        {from, field} not in deferred do
      assert order[to] < order[from], "#{from}.#{field} refers to #{to}, which comes later"
    end

    for {type, field} <- deferred do
      assert Enum.any?(context.foreign_keys, &match?({^type, _to, ^field}, &1))
    end
  end

  test "current state never refers to history, and excluded tables are never referred to",
       context do
    parts = Map.new(RecordTypes.all(), &{&1.name, &1.part})
    excluded = Map.keys(RecordTypes.excluded_tables())

    # A reference through an excluded field never reaches an archive.
    exported_reference? = fn from, field ->
      not Map.has_key?(Map.get(RecordTypes.excluded_fields(), from, %{}), field)
    end

    for {from, to, field} <- context.foreign_keys,
        Map.has_key?(parts, from),
        exported_reference?.(from, field) do
      refute to in excluded, "#{from}.#{field} refers to excluded #{to}"

      if parts[from] == :current and Map.has_key?(parts, to),
        do: assert(parts[to] == :current, "#{from}.#{field} refers to history in #{to}")
    end
  end

  test "every reference to an observation decides which observations are exported", context do
    referencing =
      for {from, "observations", field} <- context.foreign_keys,
          from not in ~w(observations observation_reconciliations),
          do: {from, field}

    assert Enum.sort(referencing) == Enum.sort(RecordTypes.observation_references())
  end
end
