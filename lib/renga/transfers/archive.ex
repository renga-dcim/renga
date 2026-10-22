defmodule Renga.Transfers.Archive do
  @moduledoc """
  The organization export archive (RFD 20): one `.tar.zst` file holding
  `manifest.json` and one newline-delimited JSON file per record type.

  This module owns the container, not what goes in it. `Renga.Transfers.Archive.Writer`
  builds an archive from record streams; `open/2` reads one back. Opening
  validates the whole container before anything can read a record: the
  archive is untrusted input, uploaded by whoever imports it, so the reader
  bounds every resource it spends and never lets an entry name choose where
  it is written.

  `open/2` checks, in order:

    * the compressed size, and the expanded size while decompressing, so a
      small archive cannot expand without bound;
    * every tar entry before extracting any: only regular files with flat
      names (`manifest.json` and `<record_type>.ndjson`) may appear, at most
      once each, so no link, directory, absolute path, or `..` reaches the
      file system;
    * the manifest's shape and format version: an archive from a newer
      release is refused, and an older format needs a converter;
    * that the archive holds exactly the files the manifest lists, each
      matching its SHA-256 checksum and record count, with every line one JSON
      object no larger than the record size limit.

  It reports every problem it can collect within those limits, up to
  `:max_problems`, rather than stopping at the first. Record contents are the
  record types' concern and are validated by the importer.

  A successful `open/2` leaves the extracted files in a private temporary
  directory until `close/1`.
  """

  alias Renga.Transfers.Archive.Lines

  @format "renga-organization-export"
  @format_version 1
  @manifest "manifest.json"
  @parts ~w(history raw_observations)
  @record_file ~r/\A[a-z][a-z0-9_]{0,62}\.ndjson\z/

  @default_limits %{
    max_compressed_bytes: 2 * 1024 * 1024 * 1024,
    max_expanded_bytes: 16 * 1024 * 1024 * 1024,
    max_files: 256,
    max_records: 50_000_000,
    max_record_bytes: 16 * 1024 * 1024,
    max_manifest_bytes: 1024 * 1024,
    max_problems: 100
  }

  @chunk_bytes 64 * 1024

  defstruct [:dir, :manifest]

  @type t :: %__MODULE__{dir: Path.t(), manifest: map()}
  @type problem :: %{file: String.t() | nil, line: pos_integer() | nil, message: String.t()}

  @doc "The value of the manifest's `format` field."
  def format, do: @format

  @doc "The archive format version this release writes and reads."
  def format_version, do: @format_version

  @doc "The optional parts an export may include."
  def parts, do: @parts

  @doc "The limits `open/2` applies unless overridden."
  def default_limits, do: @default_limits

  @doc "The file name a record type is stored under."
  def record_file(type) when is_binary(type) do
    file = type <> ".ndjson"

    if Regex.match?(@record_file, file),
      do: file,
      else: raise(ArgumentError, "invalid record type #{inspect(type)}")
  end

  @doc """
  Opens and validates the archive at `path`.

  Options are limit overrides (see `default_limits/0`) and `:tmp_dir`, the
  directory the archive is expanded under. Returns `{:ok, archive}`, or
  `{:error, problems}` with at least one problem.
  """
  @spec open(Path.t(), keyword()) :: {:ok, t()} | {:error, [problem()]}
  def open(path, opts \\ []) do
    limits = Map.merge(@default_limits, Map.new(Keyword.delete(opts, :tmp_dir)))
    dir = private_tmp_dir(opts)

    result =
      with :ok <- check_compressed_size(path, limits),
           tar = Path.join(dir, "archive.tar"),
           :ok <- decompress(path, tar, limits),
           {:ok, names} <- check_entries(tar, limits),
           files = Path.join(dir, "files"),
           :ok <- extract(tar, files, names),
           _ = File.rm(tar),
           {:ok, manifest} <- read_manifest(files, limits),
           :ok <- check_files(files, names, manifest, limits) do
        {:ok, %__MODULE__{dir: files, manifest: manifest}}
      end

    case result do
      {:ok, archive} ->
        {:ok, archive}

      {:error, problems} ->
        File.rm_rf(dir)
        {:error, problems}
    end
  end

  @doc "Removes the archive's extracted files."
  def close(%__MODULE__{dir: dir}) do
    dir |> Path.dirname() |> File.rm_rf()
    :ok
  end

  @doc "The record types the archive holds, as named in its manifest."
  def record_types(%__MODULE__{manifest: %{"files" => files}}) do
    files |> Map.keys() |> Enum.map(&Path.rootname(&1, ".ndjson")) |> Enum.sort()
  end

  @doc """
  Streams the records of `type` as decoded maps. Numbers with a fraction
  decode as `Decimal`s, as `Renga.JSON` does, so precision survives.
  An archive without the record type streams nothing.
  """
  def records(%__MODULE__{dir: dir, manifest: %{"files" => files}}, type) do
    file = record_file(type)

    if Map.has_key?(files, file) do
      dir
      |> Path.join(file)
      |> File.stream!(@chunk_bytes)
      |> Lines.stream(:infinity)
      |> Stream.map(fn {:line, line} -> Renga.JSON.decode!(line) end)
    else
      []
    end
  end

  defp private_tmp_dir(opts) do
    base = Keyword.get_lazy(opts, :tmp_dir, &System.tmp_dir!/0)
    dir = Path.join(base, "renga-archive-" <> Base.url_encode64(:crypto.strong_rand_bytes(12)))
    File.mkdir_p!(dir)
    File.chmod!(dir, 0o700)
    dir
  end

  defp check_compressed_size(path, limits) do
    case File.stat(path) do
      {:ok, %File.Stat{type: :regular, size: size}} when size > limits.max_compressed_bytes ->
        problem("the archive is #{size} bytes, over the limit of #{limits.max_compressed_bytes}")

      {:ok, %File.Stat{type: :regular}} ->
        :ok

      _other ->
        problem("the archive could not be read")
    end
  end

  # Streams the zstd frame into a tar file. Each decompression step returns
  # at most a bounded block, so the running total stops a decompression bomb
  # before it reaches the disk limit.
  defp decompress(path, tar, limits) do
    {:ok, context} = :zstd.context(:decompress)

    try do
      File.open!(tar, [:write, :binary, :raw], fn out ->
        path
        |> File.stream!(@chunk_bytes)
        |> Enum.reduce_while({:ok, 0}, fn chunk, {:ok, total} ->
          case feed(context, chunk, out, total, limits.max_expanded_bytes) do
            {:ok, total} -> {:cont, {:ok, total}}
            error -> {:halt, error}
          end
        end)
        |> case do
          {:ok, total} -> finish_decompression(context, out, total, limits.max_expanded_bytes)
          {:error, _problems} = error -> error
        end
      end)
    rescue
      ErlangError -> problem("the archive is not zstd-compressed or is corrupt")
    after
      :zstd.close(context)
    end
  end

  defp feed(context, input, out, total, max) do
    {remainder, output} =
      case :zstd.stream(context, input) do
        {:continue, remainder, output} -> {remainder, output}
        {:continue, output} -> {"", output}
      end

    total = total + IO.iodata_length(output)

    cond do
      total > max ->
        problem("the archive expands to more than #{max} bytes")

      remainder == "" ->
        :ok = IO.binwrite(out, output)
        {:ok, total}

      true ->
        :ok = IO.binwrite(out, output)
        feed(context, remainder, out, total, max)
    end
  end

  # zstd cannot tell a truncated frame from a complete one here; a truncated
  # archive fails as an invalid tar or a checksum mismatch instead.
  defp finish_decompression(context, out, total, max) do
    {:done, output} = :zstd.finish(context, "")
    total = total + IO.iodata_length(output)

    cond do
      total > max -> problem("the archive expands to more than #{max} bytes")
      total == 0 -> problem("the archive is empty or truncated")
      true -> IO.binwrite(out, output)
    end
  end

  defp check_entries(tar, limits) do
    case :erl_tar.table(String.to_charlist(tar), [:verbose]) do
      {:ok, entries} ->
        names = Enum.map(entries, &entry_name(elem(&1, 0)))

        problems =
          List.flatten([
            too_many_files(length(entries), limits),
            Enum.flat_map(entries, &entry_problems/1),
            duplicate_entries(names)
          ])

        if problems == [], do: {:ok, names}, else: {:error, cap(problems, limits)}

      {:error, _reason} ->
        problem("the archive does not contain a valid tar file")
    end
  end

  defp too_many_files(count, limits) when count > limits.max_files,
    do: [
      %{
        file: nil,
        line: nil,
        message: "the archive holds #{count} files, over the limit of #{limits.max_files}"
      }
    ]

  defp too_many_files(_count, _limits), do: []

  # Tar names are bytes; one that is not UTF-8 can never be allowed.
  defp entry_name(name) do
    case :unicode.characters_to_binary(name) do
      binary when is_binary(binary) -> binary
      _invalid -> "(unreadable name)"
    end
  end

  defp entry_problems({name, type, _size, _mtime, _mode, _uid, _gid}) do
    name = entry_name(name)

    cond do
      not allowed_name?(name) ->
        [%{file: printable(name), line: nil, message: "is not an allowed archive file name"}]

      type != :regular ->
        [%{file: name, line: nil, message: "is a #{type}, not a regular file"}]

      true ->
        []
    end
  end

  defp allowed_name?(@manifest), do: true
  defp allowed_name?(name), do: Regex.match?(@record_file, name)

  defp duplicate_entries(names) do
    names
    |> Enum.frequencies()
    |> Enum.filter(fn {_name, count} -> count > 1 end)
    |> Enum.map(fn {name, _count} ->
      %{file: name, line: nil, message: "appears more than once in the archive"}
    end)
  end

  defp printable(name) do
    name
    |> String.replace(~r/[[:cntrl:]]/u, "?")
    |> String.slice(0, 100)
  end

  defp extract(tar, dir, names) do
    File.mkdir_p!(dir)

    case :erl_tar.extract(String.to_charlist(tar), [
           {:cwd, String.to_charlist(dir)},
           {:files, Enum.map(names, &String.to_charlist/1)}
         ]) do
      :ok -> :ok
      {:error, _reason} -> problem("the archive's files could not be extracted")
    end
  end

  defp read_manifest(dir, limits) do
    path = Path.join(dir, @manifest)

    with {:ok, %File.Stat{size: size}} <- stat(path, @manifest),
         :ok <- manifest_size(size, limits),
         {:ok, manifest} <- decode_manifest(File.read!(path)),
         [] <- manifest_problems(manifest) do
      {:ok, manifest}
    else
      {:error, problems} -> {:error, problems}
      problems when is_list(problems) -> {:error, cap(problems, limits)}
    end
  end

  defp stat(path, name) do
    case File.stat(path) do
      {:ok, stat} -> {:ok, stat}
      {:error, _reason} -> {:error, [%{file: name, line: nil, message: "is missing"}]}
    end
  end

  defp manifest_size(size, limits) when size > limits.max_manifest_bytes,
    do:
      {:error,
       [%{file: @manifest, line: nil, message: "is over #{limits.max_manifest_bytes} bytes"}]}

  defp manifest_size(_size, _limits), do: :ok

  defp decode_manifest(json) do
    case Renga.JSON.decode(json) do
      {:ok, manifest} when is_map(manifest) -> {:ok, manifest}
      _other -> {:error, [%{file: @manifest, line: nil, message: "is not a JSON object"}]}
    end
  end

  defp manifest_problems(%{"format" => @format, "format_version" => version} = manifest)
       when is_integer(version) do
    cond do
      version > @format_version ->
        [
          manifest_problem(
            "was written by a newer release (format version #{version}); " <>
              "this release reads up to format version #{@format_version}"
          )
        ]

      version < 1 or version < @format_version ->
        [manifest_problem("has format version #{version}, which this release cannot convert")]

      true ->
        [
          {"renga_version", &non_empty_string?/1},
          {"organization", &organization?/1},
          {"snapshot_at", &timestamp?/1},
          {"parts", &parts?/1},
          {"files", &files?/1}
        ]
        |> Enum.reject(fn {key, valid?} -> valid?.(Map.get(manifest, key)) end)
        |> Enum.map(fn {key, _valid?} -> manifest_problem("has an invalid #{key}") end)
    end
  end

  defp manifest_problems(_manifest),
    do: [manifest_problem("is not a #{@format} manifest with a format version")]

  defp manifest_problem(message), do: %{file: @manifest, line: nil, message: message}

  defp non_empty_string?(value), do: is_binary(value) and value != ""

  defp organization?(%{"id" => id, "slug" => slug, "name" => name}),
    do:
      match?({:ok, _uuid}, Ecto.UUID.cast(id)) and non_empty_string?(slug) and
        non_empty_string?(name)

  defp organization?(_value), do: false

  defp timestamp?(value) when is_binary(value),
    do: match?({:ok, _at, 0}, DateTime.from_iso8601(value))

  defp timestamp?(_value), do: false

  defp parts?(parts) when is_list(parts),
    do: Enum.all?(parts, &(&1 in @parts)) and Enum.uniq(parts) == parts

  defp parts?(_parts), do: false

  defp files?(files) when is_map(files) do
    Enum.all?(files, fn
      {name, %{"sha256" => sha256, "records" => records, "bytes" => bytes}} ->
        Regex.match?(@record_file, name) and is_binary(sha256) and
          Regex.match?(~r/\A[0-9a-f]{64}\z/, sha256) and is_integer(records) and records >= 0 and
          is_integer(bytes) and bytes >= 0

      _file ->
        false
    end)
  end

  defp files?(_files), do: false

  defp check_files(dir, names, %{"files" => listed}, limits) do
    present = MapSet.new(names -- [@manifest])

    unlisted =
      for name <- Enum.sort(present), not Map.has_key?(listed, name) do
        %{file: name, line: nil, message: "is not listed in the manifest"}
      end

    {problems, _records} =
      listed
      |> Enum.sort()
      |> Enum.reduce({unlisted, 0}, fn {name, expected}, {problems, records} ->
        if MapSet.member?(present, name) do
          {file_problems, count} =
            check_file(Path.join(dir, name), name, expected, records, limits)

          {problems ++ file_problems, records + count}
        else
          {problems ++
             [%{file: name, line: nil, message: "is listed in the manifest but missing"}],
           records}
        end
      end)

    if problems == [], do: :ok, else: {:error, cap(problems, limits)}
  end

  # One pass over a record file computes its checksum, counts its records,
  # and checks that each is a JSON object within the size limit.
  defp check_file(path, name, expected, records_before, limits) do
    initial = %{
      hash: :crypto.hash_init(:sha256),
      bytes: 0,
      lines: Lines.new(limits.max_record_bytes),
      count: 0,
      problems: []
    }

    state =
      path
      |> File.stream!(@chunk_bytes)
      |> Enum.reduce_while(initial, fn chunk, state ->
        {items, lines} = Lines.feed(state.lines, chunk)

        state = %{
          state
          | hash: :crypto.hash_update(state.hash, chunk),
            bytes: state.bytes + byte_size(chunk),
            lines: lines
        }

        state = Enum.reduce(items, state, &check_line(&1, name, &2, records_before, limits))

        if length(state.problems) >= limits.max_problems,
          do: {:halt, state},
          else: {:cont, state}
      end)

    state =
      state.lines
      |> Lines.finish()
      |> Enum.reduce(state, &check_line(&1, name, &2, records_before, limits))

    sha256 = state.hash |> :crypto.hash_final() |> Base.encode16(case: :lower)

    summary =
      [
        sha256 != expected["sha256"] &&
          "does not match the manifest's SHA-256 checksum",
        state.bytes != expected["bytes"] &&
          "is #{state.bytes} bytes, but the manifest says #{expected["bytes"]}",
        state.count != expected["records"] &&
          "holds #{state.count} records, but the manifest says #{expected["records"]}"
      ]
      |> Enum.filter(& &1)
      |> Enum.map(&%{file: name, line: nil, message: &1})

    {Enum.reverse(state.problems) ++ summary, state.count}
  end

  defp check_line({:line, line}, name, state, records_before, limits) do
    count = state.count + 1

    problems =
      if records_before + count > limits.max_records,
        do: ["the archive holds more than #{limits.max_records} records"],
        else: record_problems(line)

    %{state | count: count, problems: add_line_problems(state.problems, name, count, problems)}
  end

  defp check_line({:too_long, _bytes}, name, state, _records_before, limits) do
    count = state.count + 1
    message = "is longer than the record limit of #{limits.max_record_bytes} bytes"
    %{state | count: count, problems: add_line_problems(state.problems, name, count, [message])}
  end

  defp check_line(:unterminated, name, state, _records_before, _limits) do
    %{
      state
      | problems: add_line_problems(state.problems, name, nil, ["does not end with a newline"])
    }
  end

  defp record_problems(line) do
    case Renga.JSON.decode(line) do
      {:ok, record} when is_map(record) -> []
      {:ok, _value} -> ["is not a JSON object"]
      {:error, _error} -> ["is not valid JSON"]
    end
  end

  defp add_line_problems(problems, name, line, messages) do
    Enum.reduce(messages, problems, &[%{file: name, line: line, message: &1} | &2])
  end

  defp cap(problems, limits) do
    if length(problems) > limits.max_problems do
      Enum.take(problems, limits.max_problems - 1) ++
        [%{file: nil, line: nil, message: "more problems were found but not listed"}]
    else
      problems
    end
  end

  defp problem(message), do: {:error, [%{file: nil, line: nil, message: message}]}
end
