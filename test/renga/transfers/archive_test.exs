defmodule Renga.Transfers.ArchiveTest do
  use ExUnit.Case, async: true

  alias Renga.Transfers.Archive
  alias Renga.Transfers.Archive.Writer

  @moduletag :tmp_dir

  @organization %{id: "6f1d5c0e-4c69-4a8a-9b65-2b4c1f0e9a11", slug: "acme", name: "Acme"}
  @snapshot_at ~U[2026-10-22 19:00:00.000Z]

  describe "a written archive" do
    test "opens with its manifest and streams its records back", %{tmp_dir: tmp} do
      path =
        write(tmp, %{
          "resources" => [%{"id" => "a", "weight" => Decimal.new("1.50")}, %{"id" => "b"}],
          "teams" => []
        })

      assert {:ok, archive} = Archive.open(path, tmp_dir: tmp)

      assert %{
               "format" => "renga-organization-export",
               "format_version" => 1,
               "renga_version" => version,
               "organization" => %{"id" => _, "slug" => "acme", "name" => "Acme"},
               "snapshot_at" => "2026-10-22T19:00:00.000Z",
               "parts" => [],
               "files" => %{
                 "resources.ndjson" => %{"records" => 2, "sha256" => <<_::binary-size(64)>>},
                 "teams.ndjson" => %{"records" => 0, "bytes" => 0}
               }
             } = archive.manifest

      assert version == to_string(Application.spec(:renga, :vsn))
      assert Archive.record_types(archive) == ["resources", "teams"]

      assert [%{"id" => "a", "weight" => weight}, %{"id" => "b"}] =
               archive |> Archive.records("resources") |> Enum.to_list()

      assert Decimal.equal?(weight, Decimal.new("1.50"))
      assert archive |> Archive.records("teams") |> Enum.to_list() == []
      assert archive |> Archive.records("cables") |> Enum.to_list() == []

      assert :ok = Archive.close(archive)
      refute File.exists?(archive.dir)
    end

    test "streams large record files in chunks", %{tmp_dir: tmp} do
      records = for i <- 1..5_000, do: %{"id" => i, "padding" => String.duplicate("x", 40)}
      path = write(tmp, %{"observations" => records})

      assert {:ok, archive} = Archive.open(path, tmp_dir: tmp)
      assert archive |> Archive.records("observations") |> Enum.count() == 5_000
      Archive.close(archive)
    end

    test "leaves no working files behind", %{tmp_dir: tmp} do
      path = write(tmp, %{"resources" => [%{"id" => "a"}]})
      assert {:ok, archive} = Archive.open(path, tmp_dir: tmp)
      Archive.close(archive)

      assert File.ls!(tmp) == [Path.basename(path)]
    end
  end

  describe "refusing an archive" do
    test "that is not zstd-compressed", %{tmp_dir: tmp} do
      path = Path.join(tmp, "plain.tar.zst")
      File.write!(path, "not an archive")

      assert {:error, [%{message: "the archive is not zstd-compressed or is corrupt"}]} =
               Archive.open(path, tmp_dir: tmp)

      assert File.ls!(tmp) == ["plain.tar.zst"]
    end

    test "that is truncated", %{tmp_dir: tmp} do
      records =
        for i <- 1..20_000,
            do: %{"id" => i, "noise" => Base.encode64(:crypto.strong_rand_bytes(30))}

      path = write(tmp, %{"resources" => records})
      data = File.read!(path)
      File.write!(path, binary_part(data, 0, div(byte_size(data), 2)))

      assert {:error, [%{message: "the archive does not contain a valid tar file"}]} =
               Archive.open(path, tmp_dir: tmp)
    end

    test "over the compressed size limit", %{tmp_dir: tmp} do
      path = write(tmp, %{"resources" => [%{"id" => "a"}]})

      assert {:error, [%{message: message}]} =
               Archive.open(path, tmp_dir: tmp, max_compressed_bytes: 10)

      assert message =~ "over the limit of 10"
    end

    test "that expands beyond the limit, before writing it all out", %{tmp_dir: tmp} do
      # About 6 KB of zstd that expands to 200 MB.
      path = Path.join(tmp, "bomb.tar.zst")
      File.write!(path, :zstd.compress(:binary.copy(<<0>>, 200_000_000)))

      assert {:error, [%{message: "the archive expands to more than 1000000 bytes"}]} =
               Archive.open(path, tmp_dir: tmp, max_expanded_bytes: 1_000_000)

      assert File.ls!(tmp) == ["bomb.tar.zst"]
    end

    test "that is not a tar file", %{tmp_dir: tmp} do
      path = Path.join(tmp, "x.tar.zst")
      File.write!(path, :zstd.compress("just some text"))

      assert {:error, [%{message: "the archive does not contain a valid tar file"}]} =
               Archive.open(path, tmp_dir: tmp)
    end

    test "with a link, a path outside the archive, or a nested name, extracting none", %{
      tmp_dir: tmp
    } do
      src = Path.join(tmp, "src")
      File.mkdir_p!(src)
      File.write!(Path.join(src, "target"), "{}\n")
      File.ln_s!("/etc/passwd", Path.join(src, "link.ndjson"))

      path =
        tar(tmp, [
          {"manifest.json", manifest(%{})},
          {:file, Path.join(src, "link.ndjson"), "link.ndjson"},
          {"../escape.ndjson", "{}\n"},
          {"/absolute.ndjson", "{}\n"},
          {"nested/resources.ndjson", "{}\n"},
          {"Resources.NDJSON", "{}\n"}
        ])

      assert {:error, problems} = Archive.open(path, tmp_dir: tmp)

      assert %{
               "link.ndjson" => "is a symlink, not a regular file",
               "../escape.ndjson" => "is not an allowed archive file name",
               "/absolute.ndjson" => "is not an allowed archive file name",
               "nested/resources.ndjson" => "is not an allowed archive file name",
               "Resources.NDJSON" => "is not an allowed archive file name"
             } == Map.new(problems, &{&1.file, &1.message})

      refute File.exists?(Path.join(tmp, "escape.ndjson"))
      assert Enum.sort(File.ls!(tmp)) == ["archive.tar.zst", "src"]
    end

    test "with a duplicated entry", %{tmp_dir: tmp} do
      path =
        tar(tmp, [
          {"manifest.json", manifest(%{"teams.ndjson" => "{}\n"})},
          {"teams.ndjson", "{}\n"},
          {"teams.ndjson", "{}\n"}
        ])

      assert {:error, [%{file: "teams.ndjson", message: "appears more than once in the archive"}]} =
               Archive.open(path, tmp_dir: tmp)
    end

    test "with too many files", %{tmp_dir: tmp} do
      files = for i <- 1..5, into: %{}, do: {"type_#{i}", [%{"id" => i}]}
      path = write(tmp, files)

      assert {:error, [%{message: "the archive holds 6 files, over the limit of 4"}]} =
               Archive.open(path, tmp_dir: tmp, max_files: 4)
    end

    test "without a manifest", %{tmp_dir: tmp} do
      path = tar(tmp, [{"teams.ndjson", "{}\n"}])

      assert {:error, [%{file: "manifest.json", message: "is missing"}]} =
               Archive.open(path, tmp_dir: tmp)
    end

    test "from a newer release", %{tmp_dir: tmp} do
      path = tar(tmp, [{"manifest.json", manifest(%{}, %{"format_version" => 2})}])

      assert {:error, [%{file: "manifest.json", message: message}]} =
               Archive.open(path, tmp_dir: tmp)

      assert message ==
               "was written by a newer release (format version 2); " <>
                 "this release reads up to format version 1"
    end

    test "with a manifest of the wrong shape", %{tmp_dir: tmp} do
      path =
        tar(tmp, [
          {"manifest.json",
           manifest(%{}, %{
             "organization" => %{"id" => "not-a-uuid", "slug" => "acme", "name" => "Acme"},
             "parts" => ["everything"],
             "snapshot_at" => "yesterday"
           })}
        ])

      assert {:error, problems} = Archive.open(path, tmp_dir: tmp)

      assert Enum.map(problems, & &1.message) == [
               "has an invalid organization",
               "has an invalid snapshot_at",
               "has an invalid parts"
             ]

      not_a_manifest = tar(tmp, [{"manifest.json", ~s({"format": "zip"})}], "other.tar.zst")

      assert {:error, [%{message: "is not a renga-organization-export manifest" <> _}]} =
               Archive.open(not_a_manifest, tmp_dir: tmp)
    end

    test "whose files differ from the manifest, reporting every problem", %{tmp_dir: tmp} do
      listed = %{"teams.ndjson" => ~s({"id":1}\n), "roles.ndjson" => ~s({"id":1}\n)}

      path =
        tar(tmp, [
          {"manifest.json", manifest(listed)},
          {"teams.ndjson", ~s({"id":2}\n{"id":3}\n)},
          {"cables.ndjson", "{}\n"}
        ])

      assert {:error, problems} = Archive.open(path, tmp_dir: tmp)

      assert Enum.map(problems, &{&1.file, &1.message}) == [
               {"cables.ndjson", "is not listed in the manifest"},
               {"roles.ndjson", "is listed in the manifest but missing"},
               {"teams.ndjson", "does not match the manifest's SHA-256 checksum"},
               {"teams.ndjson", "is 18 bytes, but the manifest says 9"},
               {"teams.ndjson", "holds 2 records, but the manifest says 1"}
             ]
    end

    test "with lines that are not JSON objects, naming each line", %{tmp_dir: tmp} do
      body = ~s({"id":1}\n[1,2]\nnot json\n\n{"id":5})

      path =
        tar(tmp, [{"manifest.json", manifest(%{"teams.ndjson" => body})}, {"teams.ndjson", body}])

      assert {:error, problems} = Archive.open(path, tmp_dir: tmp)

      assert Enum.map(problems, &{&1.line, &1.message}) == [
               {2, "is not a JSON object"},
               {3, "is not valid JSON"},
               {4, "is not valid JSON"},
               {nil, "does not end with a newline"}
             ]
    end

    test "with a record over the size limit, without buffering it", %{tmp_dir: tmp} do
      big = ~s({"id":") <> String.duplicate("x", 200_000) <> ~s("}\n)
      body = ~s({"id":1}\n) <> big <> ~s({"id":3}\n)

      path =
        tar(tmp, [{"manifest.json", manifest(%{"teams.ndjson" => body})}, {"teams.ndjson", body}])

      assert {:error, [%{line: 2, message: message}]} =
               Archive.open(path, tmp_dir: tmp, max_record_bytes: 1_000)

      assert message == "is longer than the record limit of 1000 bytes"
    end

    test "with more records than the limit", %{tmp_dir: tmp} do
      path = write(tmp, %{"a" => [%{}, %{}], "b" => [%{}, %{}]})

      assert {:error,
              [%{file: "b.ndjson", line: 2, message: "the archive holds more than 3 records"} | _]} =
               Archive.open(path, tmp_dir: tmp, max_records: 3)
    end

    test "listing at most max_problems problems", %{tmp_dir: tmp} do
      body = String.duplicate("[]\n", 50)

      path =
        tar(tmp, [{"manifest.json", manifest(%{"teams.ndjson" => body})}, {"teams.ndjson", body}])

      assert {:error, problems} = Archive.open(path, tmp_dir: tmp, max_problems: 5)
      assert length(problems) == 5
      assert List.last(problems).message == "more problems were found but not listed"
    end
  end

  test "record types must have safe file names" do
    assert Archive.record_file("cable_plans") == "cable_plans.ndjson"
    assert_raise ArgumentError, fn -> Archive.record_file("../x") end
    assert_raise ArgumentError, fn -> Archive.record_file("Cables") end
  end

  defp write(tmp, files) do
    path = Path.join(tmp, "archive.tar.zst")

    files
    |> Enum.reduce(Writer.new(tmp_dir: tmp), fn {type, records}, writer ->
      Writer.add_records(writer, type, records)
    end)
    |> Writer.finish(%{organization: @organization, snapshot_at: @snapshot_at, parts: []}, path)

    path
  end

  # A manifest listing `files` (name => contents), with `overrides` merged in.
  defp manifest(files, overrides \\ %{}) do
    %{
      "format" => "renga-organization-export",
      "format_version" => 1,
      "renga_version" => "0.0.0",
      "organization" => %{"id" => @organization.id, "slug" => "acme", "name" => "Acme"},
      "snapshot_at" => "2026-10-22T19:00:00.000Z",
      "parts" => [],
      "files" =>
        Map.new(files, fn {name, body} ->
          {name,
           %{
             "sha256" => :sha256 |> :crypto.hash(body) |> Base.encode16(case: :lower),
             "records" => body |> String.split("\n", trim: true) |> length(),
             "bytes" => byte_size(body)
           }}
        end)
    }
    |> Map.merge(overrides)
    |> Jason.encode!()
  end

  # A hand-built archive, for shapes the writer never produces.
  defp tar(tmp, entries, name \\ "archive.tar.zst") do
    tar = Path.join(tmp, "build.tar")
    {:ok, handle} = :erl_tar.open(String.to_charlist(tar), [:write])

    for entry <- entries do
      case entry do
        {:file, path, name} ->
          :ok = :erl_tar.add(handle, String.to_charlist(path), String.to_charlist(name), [])

        {name, body} ->
          :ok = :erl_tar.add(handle, body, String.to_charlist(name), [])
      end
    end

    :ok = :erl_tar.close(handle)
    path = Path.join(tmp, name)
    File.write!(path, :zstd.compress(File.read!(tar)))
    File.rm!(tar)
    path
  end
end
