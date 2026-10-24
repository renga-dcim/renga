defmodule Renga.Transfers.Schema do
  @moduledoc """
  What the database says about the tables behind the record types: each
  column's type and whether it may be null, and the foreign keys among
  record types. Exporting reads it to serialize values, and validating an
  archive reads it to check records against the release that will import
  them.
  """

  alias Renga.Repo

  @doc """
  Every column of the current schema, as
  `%{table => %{column => %{type: udt_name, nullable?: boolean, max_length: integer | nil,
  precision: integer | nil, scale: integer | nil}}}`, where precision and scale are a
  `numeric` column's, if it declares them, and max_length is each item's for a
  varchar array. Array types are named as PostgreSQL names
  them, with a leading `_`.
  """
  def columns do
    %{rows: rows} =
      Repo.query!("""
      SELECT table_name, column_name, udt_name, is_nullable = 'YES',
             -- information_schema leaves out a varchar array's element length.
             COALESCE(character_maximum_length, (
               SELECT NULLIF(attribute.atttypmod, -1) - 4
               FROM pg_attribute AS attribute
               WHERE attribute.attrelid = format('%I.%I', table_schema, table_name)::regclass
                 AND attribute.attname = column_name AND udt_name = '_varchar'
             )),
             CASE WHEN udt_name = 'numeric' THEN numeric_precision END,
             CASE WHEN udt_name = 'numeric' THEN numeric_scale END
      FROM information_schema.columns
      WHERE table_schema = current_schema()
      """)

    Enum.reduce(rows, %{}, fn [table, column, type, nullable?, max_length, precision, scale],
                              acc ->
      info = %{
        type: type,
        nullable?: nullable?,
        max_length: max_length,
        precision: precision,
        scale: scale
      }

      Map.update(acc, table, %{column => info}, &Map.put(&1, column, info))
    end)
  end

  @doc """
  The foreign keys from one of `types` to another, as maps with `:type`,
  `:fields`, `:target`, and `:target_fields`, the fields paired in order.

  `organization_id` is left out of both sides: an archive holds one
  organization and does not name it, so a key that pairs it with a record's
  ID refers to that record alone. Keys to users are principal fields
  (`Renga.Transfers.RecordTypes`), keys to organizations name the
  organization itself, and keys through fields the record type does not
  export never reach an archive; none of them is listed.
  """
  def references(types) do
    included = Map.new(types, &{&1.name, &1})

    %{rows: rows} =
      Repo.query!("""
      SELECT source.relname,
             array_agg(field.attname ORDER BY key.position),
             target.relname,
             array_agg(target_field.attname ORDER BY key.position)
      FROM pg_constraint AS constraint_
      JOIN pg_class AS source ON source.oid = constraint_.conrelid
      JOIN pg_class AS target ON target.oid = constraint_.confrelid
      CROSS JOIN LATERAL unnest(constraint_.conkey, constraint_.confkey)
        WITH ORDINALITY AS key(field, target_field, position)
      JOIN pg_attribute AS field
        ON field.attrelid = constraint_.conrelid AND field.attnum = key.field
      JOIN pg_attribute AS target_field
        ON target_field.attrelid = constraint_.confrelid AND target_field.attnum = key.target_field
      WHERE constraint_.contype = 'f'
        AND source.relnamespace = current_schema()::regnamespace
      GROUP BY constraint_.oid, source.relname, target.relname
      ORDER BY source.relname, constraint_.oid
      """)

    for [table, fields, target, target_fields] <- rows,
        Map.has_key?(included, table),
        target not in ~w(users organizations),
        pairs =
          Enum.reject(
            Enum.zip(fields, target_fields),
            &(&1 == {"organization_id", "organization_id"})
          ),
        pairs != [],
        exported = Enum.filter(pairs, &(elem(&1, 0) in included[table].fields)),
        exported != [] do
      unless Map.has_key?(included, target),
        do: raise(ArgumentError, "#{table} refers to #{target}, which the archive does not hold")

      unless exported == pairs,
        do:
          raise(ArgumentError, "#{table} refers to #{target} through a field it does not export")

      %{
        type: table,
        fields: Enum.map(pairs, &elem(&1, 0)),
        target: target,
        target_fields: Enum.map(pairs, &elem(&1, 1))
      }
    end
  end
end
