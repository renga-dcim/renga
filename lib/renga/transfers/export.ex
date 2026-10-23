defmodule Renga.Transfers.Export do
  @moduledoc """
  Writes an organization's export archive (RFD 20).

  Every record type is read inside one repeatable-read, read-only
  transaction, so the archive is one consistent snapshot of the organization
  even while agents keep reporting. Rows are serialized by PostgreSQL and
  streamed to the archive writer a batch at a time, so no record type is held
  in memory.

  This module reads whatever it is asked to: callers authorize the export
  (an owner's `organization.export`, or an operator's release command) and
  record it.

  Values are written as JSON: UUIDs, text, and addresses as strings,
  numbers as numbers at full precision, timestamps as ISO 8601 UTC strings
  with microseconds, binary values in base64, and JSON columns as they are.
  """

  alias Ecto.Adapters.SQL
  alias Renga.Accounts.Organization
  alias Renga.Repo
  alias Renga.Transfers.Archive
  alias Renga.Transfers.Archive.Writer
  alias Renga.Transfers.RecordTypes

  @batch_rows 500
  # jsonb_build_object takes at most 100 arguments, so wide rows are built
  # from several objects concatenated.
  @fields_per_object 40

  @doc """
  Exports `organization` to a new archive at `path`.

  Options:

    * `:parts` - optional parts to include (`Archive.parts/0`), default none
    * `:tmp_dir` - where the archive is assembled

  Returns `{:ok, %{snapshot_at: at, records: count}}`.
  """
  def write(%Organization{} = organization, path, opts \\ []) do
    parts = Keyword.get(opts, :parts, [])

    unless Enum.all?(parts, &(&1 in Archive.parts())),
      do: raise(ArgumentError, "unknown export parts #{inspect(parts)}")

    writer = Writer.new(Keyword.take(opts, [:tmp_dir]))

    try do
      {writer, snapshot_at, organization} =
        snapshot(fn -> write_records(writer, organization, parts, opts) end)

      :ok =
        Writer.finish(
          writer,
          %{organization: organization, snapshot_at: snapshot_at, parts: parts},
          path
        )

      records = writer.files |> Map.values() |> Enum.map(& &1["records"]) |> Enum.sum()
      {:ok, %{snapshot_at: snapshot_at, records: records}}
    rescue
      exception ->
        Writer.discard(writer)
        reraise exception, __STACKTRACE__
    end
  end

  # The manifest names the organization as the snapshot found it, which
  # the organization record must match.
  defp write_records(writer, organization, parts, opts) do
    snapshot_at = snapshot_time()
    organization = Repo.get!(Organization, organization.id)
    columns = column_types()
    types = RecordTypes.included(parts)
    after_type = Keyword.get(opts, :after_record_type, fn _type -> :ok end)
    params = [Ecto.UUID.dump!(organization.id)]

    writer =
      Writer.add_json(writer, "organization", rows(organization_sql(columns), params))

    writer =
      Enum.reduce(types, writer, fn type, writer ->
        writer =
          Writer.add_json(
            writer,
            type.name,
            rows(type_sql(type, types, parts, columns), params)
          )

        after_type.(type.name)
        writer
      end)

    writer = Writer.add_json(writer, "principals", rows(principals_sql(types), params))
    {writer, snapshot_at, organization}
  end

  # The snapshot must be the transaction's first statement, so the export
  # cannot run inside another transaction. Statements may run as long as
  # approved background work (RFD 21); each fetches one batch.
  defp snapshot(fun) do
    {:ok, result} =
      Repo.transaction(
        fn ->
          if repeatable_read?(),
            do: Repo.query!("SET TRANSACTION ISOLATION LEVEL REPEATABLE READ, READ ONLY")

          Repo.query!("SELECT set_config('statement_timeout', $1, true)", [
            "#{Repo.background_statement_timeout_ms()}ms"
          ])

          fun.()
        end,
        timeout: :infinity
      )

    result
  end

  # The SQL sandbox runs each test inside a transaction that has already
  # begun, where the isolation level can no longer be set; test config turns
  # this off, and the concurrency test turns it back on outside the sandbox.
  defp repeatable_read? do
    :renga |> Application.get_env(__MODULE__, []) |> Keyword.get(:repeatable_read, true)
  end

  defp snapshot_time do
    %{rows: [[at]]} = Repo.query!("SELECT now()")
    Renga.Time.floor_to_millisecond(at)
  end

  defp rows(sql, params) do
    Repo
    |> SQL.stream(sql, params, max_rows: @batch_rows, timeout: :infinity)
    |> Stream.flat_map(fn %{rows: rows} -> Enum.map(rows, fn [json] -> json end) end)
  end

  defp column_types do
    %{rows: rows} =
      Repo.query!("""
      SELECT table_name, column_name, udt_name
      FROM information_schema.columns
      WHERE table_schema = current_schema()
      """)

    Enum.reduce(rows, %{}, fn [table, column, type], acc ->
      Map.update(acc, table, %{column => type}, &Map.put(&1, column, type))
    end)
  end

  defp organization_sql(columns) do
    """
    SELECT #{json_object("organizations", RecordTypes.organization_fields(), columns)}
    FROM organizations AS t
    WHERE t.id = $1
    """
  end

  defp type_sql(type, types, parts, columns) do
    """
    SELECT #{json_object(type.name, type.fields, columns)}
    FROM #{quote_name(type.name)} AS t
    WHERE t.organization_id = $1#{filter(type.name, types, parts)}
    ORDER BY #{Enum.map_join(type.order_by, ", ", &("t." <> quote_name(&1)))}
    """
  end

  # Without raw observations, only the observations the included records
  # point at are exported, with the reports they were split from.
  defp filter("observations", types, parts) do
    if "raw_observations" in parts,
      do: "",
      else: "\n  AND t.id IN (#{needed_observations(types)})"
  end

  defp filter("observation_reconciliations", types, parts) do
    if "raw_observations" in parts,
      do: "",
      else: "\n  AND t.observation_id IN (#{needed_observations(types)})"
  end

  defp filter(_type, _types, _parts), do: ""

  defp needed_observations(types) do
    included = MapSet.new(types, & &1.name)

    referenced =
      for {type, field} <- RecordTypes.observation_references(), type in included do
        "SELECT r.#{quote_name(field)} FROM #{quote_name(type)} AS r " <>
          "WHERE r.organization_id = $1 AND r.#{quote_name(field)} IS NOT NULL"
      end

    """
    WITH RECURSIVE needed(id) AS (
      #{Enum.join(referenced, "\n  UNION ")}
      UNION
      SELECT o.parent_observation_id FROM observations AS o
      JOIN needed ON o.id = needed.id
      WHERE o.organization_id = $1 AND o.parent_observation_id IS NOT NULL
    )
    SELECT id FROM needed
    """
  end

  # A principal for everyone the included records name, with their email
  # while their account exists.
  defp principals_sql(types) do
    references =
      for type <- types, {field, condition} <- type.principal_fields do
        "SELECT r.#{quote_name(field)} AS id FROM #{quote_name(type.name)} AS r " <>
          "WHERE r.organization_id = $1 AND r.#{quote_name(field)} IS NOT NULL" <>
          if(condition, do: " AND (#{condition})", else: "")
      end

    # An account an organization provider created has no global email
    # (RFD 15); the organization names it by the address its own provider
    # verified, which is what invites the person back after an import.
    # Other organizations' providers never reach the archive.
    """
    SELECT jsonb_build_object('id', p.id, 'email', COALESCE(u.email, (
      SELECT i.email
      FROM user_identities AS i
      JOIN identity_providers AS ip ON ip.id = i.provider_id
      WHERE i.user_id = p.id AND i.email IS NOT NULL AND i.email_verified
        AND ip.organization_id = $1 AND ip.removed_at IS NULL
      ORDER BY i.last_signed_in_at DESC NULLS LAST, i.id
      LIMIT 1
    )))::text
    FROM (#{Enum.join(references, "\nUNION ")}) AS p
    LEFT JOIN users AS u ON u.id = p.id
    ORDER BY p.id
    """
  end

  defp json_object(table, fields, columns) do
    types = Map.fetch!(columns, table)

    objects =
      fields
      |> Enum.chunk_every(@fields_per_object)
      |> Enum.map(fn chunk ->
        pairs =
          Enum.map_join(chunk, ", ", fn field ->
            type =
              Map.get(types, field) ||
                raise ArgumentError, "#{table}.#{field} is not a column"

            "'#{field}', #{value(field, type)}"
          end)

        "jsonb_build_object(#{pairs})"
      end)

    "(#{Enum.join(objects, " || ")})::text"
  end

  defp value(field, "timestamp"),
    do: ~s|to_char(t.#{quote_name(field)}, 'YYYY-MM-DD"T"HH24:MI:SS.US"Z"')|

  defp value(field, "timestamptz"),
    do: ~s|to_char(t.#{quote_name(field)} AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.US"Z"')|

  # encode() wraps base64 every 76 characters.
  defp value(field, "bytea"),
    do: "translate(encode(t.#{quote_name(field)}, 'base64'), E'\\n', '')"

  defp value(field, _type), do: "t.#{quote_name(field)}"

  defp quote_name(name) do
    unless Regex.match?(~r/\A[a-z_][a-z0-9_]*\z/, name),
      do: raise(ArgumentError, "unsafe SQL name #{inspect(name)}")

    ~s("#{name}")
  end
end
