defmodule Renga.Transfers.Validation do
  @moduledoc """
  Validates the records of an opened archive before anything is imported
  (RFD 20).

  `Renga.Transfers.Archive.open/2` has already checked the container: safe
  entries, sizes, checksums, and that every line is a JSON object. This
  checks what the records say, against the record types of the archive's
  format version and the database schema of this release:

    * the archive holds exactly the record files its parts call for;
    * every record has exactly its type's fields, each value of its
      column's type, and no null where the column requires a value;
    * no two records of a type share an ID;
    * every reference stays inside the archive: a field that refers to
      another record names one the archive holds (foreign keys that also pair
      fields, such as an evidence row's observation and source, must match the
      same record), and every field that names a person names a principal in
      `principals.ndjson`.

  Because records never name their organization and every reference must
  resolve inside the archive, a valid archive cannot reach another
  organization's records. Checks the database enforces on insert, such as
  allowed values and uniqueness across fields, are left to the import's
  transaction, which rolls back whole.

  It reports every problem it finds, up to `:max_problems`, in the shape
  `Archive.open/2` uses. Validation reads the archive twice, first checking
  records and noting their keys, then resolving references; the keys are
  held in an ETS table for the duration of the call.
  """

  alias Renga.Transfers.Archive
  alias Renga.Transfers.RecordTypes
  alias Renga.Transfers.Schema

  @uuid ~r/\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/i
  @mac_address ~r/\A[0-9a-f]{2}(:[0-9a-f]{2}){5}\z/i
  @int4range ~r/\A(empty|[\[(]-?\d*,-?\d*[\])])\z/
  @int4 {-2_147_483_648, 2_147_483_647}
  @int8 {-9_223_372_036_854_775_808, 9_223_372_036_854_775_807}

  @doc """
  Validates `archive`'s records. Returns `:ok` or `{:error, problems}`.

  Options: `:max_problems`, which defaults to the archive limit of the same
  name.
  """
  @spec validate(Archive.t(), keyword()) :: :ok | {:error, [Archive.problem()]}
  def validate(%Archive{manifest: manifest} = archive, opts \\ []) do
    max = Keyword.get(opts, :max_problems, Archive.default_limits().max_problems)
    types = RecordTypes.included(manifest["parts"])

    case file_problems(archive, types) do
      [] -> validate_records(archive, types, max)
      problems -> {:error, cap(problems, max)}
    end
  end

  defp file_problems(archive, types) do
    expected = Enum.map(types, & &1.name) ++ ~w(organization principals)
    present = Archive.record_types(archive)

    missing =
      for type <- Enum.sort(expected -- present),
          do: problem(Archive.record_file(type), nil, "is missing")

    unexpected =
      for type <- present -- expected do
        problem(Archive.record_file(type), nil, "is not a record type of this export")
      end

    missing ++ unexpected
  end

  defp validate_records(archive, types, max) do
    columns = Schema.columns()

    context = %{
      archive: archive,
      types: types,
      columns: columns,
      references: Enum.group_by(Schema.references(types), & &1.type),
      keys: :ets.new(__MODULE__, [:set, :private]),
      problems: problems(max)
    }

    try do
      context
      |> check_organization()
      |> check_principals()
      |> check_types()
      |> check_references()
      |> result()
    after
      :ets.delete(context.keys)
    end
  end

  # The keys other records refer to: each type's ID, and the field
  # combinations composite references match on.
  defp keys_of(context, type) do
    targets =
      for {_type, references} <- context.references,
          reference <- references,
          reference.target == type.name,
          reference.target_fields != type.order_by,
          uniq: true,
          do: reference.target_fields

    [type.order_by | targets]
  end

  defp check_organization(context) do
    fields = RecordTypes.organization_fields()
    columns = Map.fetch!(context.columns, "organizations")
    manifest = context.archive.manifest["organization"]

    {context, count} =
      context.archive
      |> Archive.records("organization")
      |> Enum.reduce_while({context, 0}, fn record, {context, count} ->
        line = count + 1

        messages =
          if line == 1,
            do:
              record_messages(record, fields, columns) ++ organization_messages(record, manifest),
            else: ["is a second organization; an archive holds one"]

        context = add(context, "organization", line, messages)
        {action, context} = continue(context)
        {action, {context, line}}
      end)

    if count == 0, do: add(context, "organization", nil, ["holds no organization"]), else: context
  end

  defp organization_messages(record, manifest) do
    for field <- ~w(slug name), record[field] != manifest[field] do
      ~s(field "#{field}" does not match the manifest's organization)
    end
  end

  defp check_principals(context) do
    fields = RecordTypes.principal_record_fields()

    columns = %{
      "id" => %{type: "uuid", nullable?: false, max_length: nil},
      "email" => %{type: "text", nullable?: true, max_length: nil}
    }

    scan(context, "principals", fn record, line, context ->
      messages =
        record_messages(record, fields, columns) ++
          note_keys(context, "principals", [["id"]], record, line, columns)

      add(context, "principals", line, messages)
    end)
  end

  defp check_types(context) do
    Enum.reduce_while(context.types, context, fn type, context ->
      columns = Map.fetch!(context.columns, type.name)
      keys = keys_of(context, type)

      context
      |> scan(type.name, fn record, line, context ->
        messages =
          record_messages(record, type.fields, columns) ++
            note_keys(context, type.name, keys, record, line, columns)

        add(context, type.name, line, messages)
      end)
      |> continue()
    end)
  end

  # Notes the record's keys for references to resolve. The first is its
  # primary key, which no other record of the type may repeat. A key with a
  # missing or invalid value is not noted; that field has its own problem.
  defp note_keys(context, type, [primary | others], record, line, columns) do
    for fields <- others, values = values(record, fields), checkable?(fields, values, columns) do
      :ets.insert(context.keys, {{type, fields, normalize(values)}, line})
    end

    values = values(record, primary)

    with true <- checkable?(primary, values, columns),
         key = {type, primary, normalize(values)},
         false <- :ets.insert_new(context.keys, {key, line}) do
      [{_key, first}] = :ets.lookup(context.keys, key)
      ["has the same #{key_name(primary)} as line #{first}"]
    else
      _noted -> []
    end
  end

  defp values(record, fields), do: Enum.map(fields, &Map.get(record, &1))

  defp key_name(["id"]), do: "ID"
  defp key_name(fields), do: Enum.map_join(fields, " and ", &~s("#{&1}"))

  # UUIDs compare case-insensitively, as PostgreSQL compares them.
  defp normalize(values),
    do: Enum.map(values, &if(is_binary(&1), do: String.downcase(&1), else: &1))

  defp check_references(context) do
    Enum.reduce_while(context.types, context, fn type, context ->
      context |> check_type_references(type) |> continue()
    end)
  end

  defp check_type_references(context, type) do
    references = Map.get(context.references, type.name, [])
    columns = Map.fetch!(context.columns, type.name)

    if references == [] and type.principal_fields == [] do
      context
    else
      scan(context, type.name, fn record, line, context ->
        messages =
          reference_messages(context, record, references, columns) ++
            principal_messages(context, record, type.principal_fields, columns)

        add(context, type.name, line, messages)
      end)
    end
  end

  defp reference_messages(context, record, references, columns) do
    for reference <- references,
        values = values(record, reference.fields),
        checkable?(reference.fields, values, columns),
        not :ets.member(
          context.keys,
          {reference.target, reference.target_fields, normalize(values)}
        ) do
      case reference.fields do
        [field] ->
          ~s(field "#{field}" refers to #{reference.target} record #{List.first(values)}, which the archive does not hold)

        fields ->
          "fields #{key_name(fields)} (#{Enum.join(values, ", ")}) match no " <>
            "#{reference.target} record the archive holds"
      end
    end
  end

  # A foreign key with a null field is not checked, as PostgreSQL does not
  # check it; an invalid value already has its own problem.
  defp checkable?(fields, values, columns) do
    Enum.all?(values, &(not is_nil(&1))) and
      fields
      |> Enum.zip(values)
      |> Enum.all?(fn {field, value} -> valid?(value, columns[field]) end)
  end

  defp principal_messages(context, record, principal_fields, columns) do
    for {field, condition} <- principal_fields,
        names_person?(record, condition),
        value = Map.get(record, field),
        checkable?([field], [value], columns),
        not :ets.member(context.keys, {"principals", ["id"], normalize([value])}) do
      ~s(field "#{field}" refers to principal #{value}, which principals.ndjson does not hold)
    end
  end

  defp names_person?(_record, nil), do: true
  defp names_person?(record, {field, value}), do: Map.get(record, field) == value

  # Fields, then each value against its column.
  defp record_messages(record, fields, columns) do
    unknown =
      for field <- record |> Map.keys() |> Enum.sort(), field not in fields do
        ~s(has a field "#{printable(field)}" its record type does not have)
      end

    missing =
      for field <- fields, not Map.has_key?(record, field), do: ~s(is missing field "#{field}")

    values =
      for field <- fields,
          Map.has_key?(record, field),
          message = value_message(Map.get(record, field), Map.fetch!(columns, field)),
          do: ~s(field "#{field}" #{message})

    unknown ++ missing ++ values
  end

  defp value_message(nil, %{nullable?: true}), do: nil
  defp value_message(nil, %{nullable?: false}), do: "must have a value"

  defp value_message(value, column) do
    cond do
      not valid?(value, column) -> "must be #{describe(column.type)}"
      too_long?(value, column) -> "is longer than #{column.max_length} characters"
      true -> nil
    end
  end

  defp too_long?(value, %{max_length: max}) when is_integer(max) and is_binary(value),
    do: String.length(value) > max

  defp too_long?(_value, _column), do: false

  # Whether a JSON value can be stored in a column of this type. Types
  # the archive does not use are left to the database.
  defp valid?(nil, %{nullable?: nullable?}), do: nullable?
  defp valid?(value, %{type: type}), do: valid_type?(value, type)

  defp valid_type?(value, "uuid"), do: is_binary(value) and Regex.match?(@uuid, value)
  defp valid_type?(value, type) when type in ~w(text varchar citext), do: is_binary(value)
  defp valid_type?(value, "int4"), do: in_range?(value, @int4)
  defp valid_type?(value, "int8"), do: in_range?(value, @int8)
  defp valid_type?(value, "numeric"), do: is_integer(value) or is_struct(value, Decimal)
  defp valid_type?(value, "bool"), do: is_boolean(value)
  defp valid_type?(value, type) when type in ~w(timestamp timestamptz), do: timestamp?(value)
  defp valid_type?(value, "bytea"), do: is_binary(value) and Base.decode64(value) != :error
  defp valid_type?(_value, type) when type in ~w(jsonb json), do: true
  defp valid_type?(value, "inet"), do: address?(value, false)
  defp valid_type?(value, "cidr"), do: address?(value, true)
  defp valid_type?(value, "macaddr"), do: is_binary(value) and Regex.match?(@mac_address, value)
  defp valid_type?(value, "int4range"), do: is_binary(value) and Regex.match?(@int4range, value)

  defp valid_type?(value, "_" <> type) when is_list(value),
    do: Enum.all?(value, &(not is_nil(&1) and valid_type?(&1, type)))

  defp valid_type?(_value, "_" <> _type), do: false
  defp valid_type?(_value, _type), do: true

  defp in_range?(value, {min, max}), do: is_integer(value) and value >= min and value <= max

  defp timestamp?(value) when is_binary(value),
    do: match?({:ok, _at, _offset}, DateTime.from_iso8601(value))

  defp timestamp?(_value), do: false

  defp address?(value, network?) when is_binary(value) do
    case String.split(value, "/") do
      [address] -> not network? and ip?(address)
      [address, length] -> ip?(address) and prefix_length?(address, length)
      _other -> false
    end
  end

  defp address?(_value, _network?), do: false

  defp ip?(address),
    do: match?({:ok, _ip}, :inet.parse_strict_address(String.to_charlist(address)))

  defp prefix_length?(address, length) do
    max = if String.contains?(address, ":"), do: 128, else: 32

    case Integer.parse(length) do
      {length, ""} -> length >= 0 and length <= max
      _other -> false
    end
  end

  defp describe("uuid"), do: "a UUID"
  defp describe(type) when type in ~w(text varchar citext), do: "a string"
  defp describe(type) when type in ~w(int4 int8), do: "an integer in range"
  defp describe("numeric"), do: "a number"
  defp describe("bool"), do: "true or false"
  defp describe(type) when type in ~w(timestamp timestamptz), do: "an ISO 8601 timestamp"
  defp describe("bytea"), do: "base64"
  defp describe("inet"), do: "an IP address"
  defp describe("cidr"), do: "an IP network"
  defp describe("macaddr"), do: "a MAC address"
  defp describe("int4range"), do: "an integer range"
  defp describe("_" <> type), do: "a list, each item #{describe(type)}"

  defp printable(field), do: field |> String.slice(0, 64) |> inspect() |> String.trim("\"")

  # Problems are collected newest first, up to the limit; one more marks
  # that the list is incomplete and stops the scan.
  defp problems(max), do: %{list: [], count: 0, max: max, more?: false}

  defp add(context, _file, _line, []), do: context

  defp add(%{problems: problems} = context, file, line, messages) do
    problems =
      Enum.reduce(messages, problems, fn message, problems ->
        if problems.count < problems.max - 1 do
          %{
            problems
            | list: [problem(Archive.record_file(file), line, message) | problems.list],
              count: problems.count + 1
          }
        else
          %{problems | more?: true}
        end
      end)

    %{context | problems: problems}
  end

  defp scan(context, type, fun) do
    context.archive
    |> Archive.records(type)
    |> Stream.with_index(1)
    |> Enum.reduce_while(context, fn {record, line}, context ->
      continue(fun.(record, line, context))
    end)
  end

  defp continue(%{problems: %{more?: true}} = context), do: {:halt, context}
  defp continue(context), do: {:cont, context}

  defp result(%{problems: %{list: [], more?: false}}), do: :ok

  defp result(%{problems: problems}) do
    more =
      if problems.more?,
        do: [problem(nil, nil, "more problems were found but not listed")],
        else: []

    {:error, Enum.reverse(problems.list) ++ more}
  end

  defp cap(problems, max) do
    if length(problems) > max,
      do:
        Enum.take(problems, max - 1) ++
          [problem(nil, nil, "more problems were found but not listed")],
      else: problems
  end

  defp problem(file, line, message), do: %{file: file, line: line, message: message}
end
