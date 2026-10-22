defmodule Renga.Transfers.Archive.Writer do
  @moduledoc """
  Builds an organization export archive (`Renga.Transfers.Archive`).

  Records are written as they stream in, one JSON object per line, into a
  private temporary directory, and each file's checksum, size, and record
  count are computed on the way. `finish/3` then writes the manifest, packs
  the files into a tar, and compresses it, so an export never holds a whole
  record type in memory.

      writer = Writer.new()
      writer = Writer.add_records(writer, "resources", stream_of_maps)
      writer = Writer.add_json(writer, "teams", stream_of_json_objects)
      :ok = Writer.finish(writer, %{organization: org, snapshot_at: at, parts: []}, path)

  A writer that is abandoned instead of finished must be `discard/1`ed.
  """

  alias Renga.Transfers.Archive

  @manifest "manifest.json"

  defstruct [:dir, files: %{}]

  @doc "Starts an archive in a private directory under `:tmp_dir`."
  def new(opts \\ []) do
    base = Keyword.get_lazy(opts, :tmp_dir, &System.tmp_dir!/0)
    dir = Path.join(base, "renga-export-" <> Base.url_encode64(:crypto.strong_rand_bytes(12)))
    File.mkdir_p!(dir)
    File.chmod!(dir, 0o700)
    %__MODULE__{dir: dir}
  end

  @doc """
  Writes `records`, an enumerable of JSON-encodable maps, as record type
  `type`. Each type may be added once; a type with no records still gets an
  empty file, so the archive says it has none rather than omitting it.
  """
  def add_records(%__MODULE__{} = writer, type, records) do
    add_json(writer, type, Stream.map(records, &Renga.JSON.encode_to_iodata!/1))
  end

  @doc """
  Like `add_records/3`, for records already encoded as JSON objects, such as
  rows PostgreSQL serialized. Each must be one JSON object without a newline;
  the writer trusts its caller for that.
  """
  def add_json(%__MODULE__{} = writer, type, records) do
    file = Archive.record_file(type)

    if Map.has_key?(writer.files, file),
      do: raise(ArgumentError, "record type #{type} was already added")

    initial = {:crypto.hash_init(:sha256), 0, 0}

    {hash, count, bytes} =
      File.open!(Path.join(writer.dir, file), [:write, :binary, :raw, :delayed_write], fn out ->
        Enum.reduce(records, initial, fn record, {hash, count, bytes} ->
          line = [record, ?\n]
          :ok = IO.binwrite(out, line)
          {:crypto.hash_update(hash, line), count + 1, bytes + IO.iodata_length(line)}
        end)
      end)

    entry = %{
      "sha256" => hash |> :crypto.hash_final() |> Base.encode16(case: :lower),
      "records" => count,
      "bytes" => bytes
    }

    %{writer | files: Map.put(writer.files, file, entry)}
  end

  @doc """
  Writes the manifest and the compressed archive to `path`, then removes the
  working directory.

  `attrs` holds `:organization` (with `id`, `slug`, and `name`),
  `:snapshot_at`, and `:parts`, the optional parts included.
  """
  def finish(%__MODULE__{} = writer, attrs, path) do
    organization = Map.fetch!(attrs, :organization)
    parts = Map.get(attrs, :parts, [])

    unless Enum.all?(parts, &(&1 in Archive.parts())),
      do: raise(ArgumentError, "unknown archive parts #{inspect(parts)}")

    manifest = %{
      "format" => Archive.format(),
      "format_version" => Archive.format_version(),
      "renga_version" => renga_version(),
      "organization" => %{
        "id" => organization.id,
        "slug" => organization.slug,
        "name" => organization.name
      },
      "snapshot_at" => attrs |> Map.fetch!(:snapshot_at) |> DateTime.to_iso8601(),
      "parts" => parts,
      "files" => writer.files
    }

    File.write!(Path.join(writer.dir, @manifest), Jason.encode_to_iodata!(manifest, pretty: true))

    tar = Path.join(writer.dir, "archive.tar")
    pack(writer, tar)
    compress(tar, path)
    :ok
  after
    discard(writer)
  end

  @doc "Removes the working directory of an unfinished archive."
  def discard(%__MODULE__{dir: dir}) do
    File.rm_rf(dir)
    :ok
  end

  # The manifest goes first so a reader streaming the tar sees it before the
  # records it describes.
  defp pack(writer, tar) do
    {:ok, handle} = :erl_tar.open(String.to_charlist(tar), [:write])

    try do
      for name <- [@manifest | writer.files |> Map.keys() |> Enum.sort()] do
        :ok =
          :erl_tar.add(
            handle,
            String.to_charlist(Path.join(writer.dir, name)),
            String.to_charlist(name),
            []
          )
      end
    after
      :ok = :erl_tar.close(handle)
    end
  end

  defp compress(tar, path) do
    {:ok, context} = :zstd.context(:compress)

    try do
      File.open!(path, [:write, :binary, :raw], fn out ->
        tar
        |> File.stream!(64 * 1024)
        |> Enum.each(&compress_chunk(context, &1, out))

        {:done, output} = :zstd.finish(context, "")
        :ok = IO.binwrite(out, output)
      end)
    after
      :zstd.close(context)
    end
  end

  defp compress_chunk(context, chunk, out) do
    case :zstd.stream(context, chunk) do
      {:continue, output} ->
        :ok = IO.binwrite(out, output)

      {:continue, remainder, output} ->
        :ok = IO.binwrite(out, output)
        compress_chunk(context, remainder, out)
    end
  end

  defp renga_version, do: :renga |> Application.spec(:vsn) |> to_string()
end
