defmodule Renga.Transfers.RoundTripTest do
  @moduledoc """
  RFD 20's round-trip fixtures. `test/fixtures/transfers/format-N/` holds
  an archive of every format version, written once and never changed: its
  manifest, its record files, and `fixture.json`, which names the records
  the assertions look for. Each must import into this release, through the
  converters from its version (`Renga.Transfers.Converters`), and export
  again as a valid archive.

  A change that breaks an older fixture changed an exported shape: bump the
  archive format version, add a converter from the version before, and
  write the new version's fixture with

      mix test test/renga/transfers/round_trip_test.exs --only write_transfer_fixture
  """
  use Renga.DataCase, async: true

  import Renga.TransfersFixtures

  alias Renga.Accounts
  alias Renga.Accounts.Organization
  alias Renga.Inventory
  alias Renga.Jobs
  alias Renga.Jobs.Job
  alias Renga.SavedViews.SavedView
  alias Renga.Transfers.Archive
  alias Renga.Transfers.Archive.Writer
  alias Renga.Transfers.Converters
  alias Renga.Transfers.Export
  alias Renga.Transfers.Import
  alias Renga.Transfers.Principals
  alias Renga.Transfers.RecordTypes
  alias Renga.Transfers.Validation

  @moduletag :tmp_dir
  @fixtures Path.expand("../../fixtures/transfers", __DIR__)
  @parts ~w(history)

  test "every earlier format version has a converter and a fixture" do
    current = Archive.format_version()
    assert Converters.versions() == Enum.to_list(1..(current - 1)//1)

    assert fixture_versions() == Enum.to_list(1..current),
           "write format version #{current}'s fixture (see this module's docs)"
  end

  for version <- Path.wildcard(Path.join(@fixtures, "format-*")) |> Enum.map(&Path.basename/1) do
    test "the #{version} fixture imports and exports again", %{tmp_dir: tmp} do
      dir = Path.join(@fixtures, unquote(version))
      {path, expected} = build_fixture(dir, tmp)
      target = organization_fixture()

      assert {:ok, _import} = import_archive(path, target, tmp)
      assert_round_trip(target, expected, tmp)
    end
  end

  test "this release's exports carry everything the fixtures check", %{tmp_dir: tmp} do
    context = round_trip_organization()
    path = Path.join(tmp, "live.tar.zst")
    {:ok, _summary} = Export.write(context.organization, path, parts: @parts)
    Repo.delete!(context.organization)
    target = organization_fixture()

    assert {:ok, _import} = import_archive(path, target, tmp)
    assert_round_trip(target, expected(context), tmp)
  end

  @tag :write_transfer_fixture
  test "writes this format version's fixture", %{tmp_dir: tmp} do
    context = round_trip_organization()
    path = Path.join(tmp, "fixture.tar.zst")
    {:ok, _summary} = Export.write(context.organization, path, parts: @parts)
    {:ok, archive} = Archive.open(path, tmp_dir: tmp)

    dir = Path.join(@fixtures, "format-#{Archive.format_version()}")
    File.rm_rf!(dir)
    File.mkdir_p!(dir)

    for file <- Map.keys(archive.manifest["files"]),
        do: File.cp!(Path.join(archive.dir, file), Path.join(dir, file))

    manifest = Map.take(archive.manifest, ~w(format_version organization snapshot_at parts))
    File.write!(Path.join(dir, "manifest.json"), Jason.encode!(manifest, pretty: true) <> "\n")

    File.write!(
      Path.join(dir, "fixture.json"),
      Jason.encode!(expected(context), pretty: true) <> "\n"
    )

    Archive.close(archive)
  end

  defp fixture_versions do
    Path.join(@fixtures, "format-*")
    |> Path.wildcard()
    |> Enum.map(&(&1 |> Path.basename() |> String.trim_leading("format-") |> String.to_integer()))
    |> Enum.sort()
  end

  defp expected(context) do
    %{
      "managed_principal" => context.managed.user.id,
      "former_principal" => context.former.user.id,
      "viewer_principal" => context.viewer.user.id,
      "private_view" => context.private_view.id,
      "shared_view" => context.shared_view.id,
      "queued_job" => context.job.id,
      "resource" => context.resource.id
    }
  end

  # Packs a fixture's files into an archive of its format version.
  defp build_fixture(dir, tmp) do
    manifest = dir |> Path.join("manifest.json") |> File.read!() |> Jason.decode!()

    writer =
      dir
      |> Path.join("*.ndjson")
      |> Path.wildcard()
      |> Enum.reduce(Writer.new(tmp_dir: tmp), fn file, writer ->
        lines = file |> File.stream!() |> Stream.map(&String.trim_trailing(&1, "\n"))
        Writer.add_json(writer, Path.basename(file, ".ndjson"), lines)
      end)

    organization = manifest["organization"]
    {:ok, snapshot_at, 0} = DateTime.from_iso8601(manifest["snapshot_at"])
    path = Path.join(tmp, "#{Path.basename(dir)}.tar.zst")

    :ok =
      Writer.finish(
        writer,
        %{
          organization: %{
            id: organization["id"],
            slug: organization["slug"],
            name: organization["name"]
          },
          snapshot_at: snapshot_at,
          parts: manifest["parts"],
          format_version: manifest["format_version"]
        },
        path
      )

    {path, dir |> Path.join("fixture.json") |> File.read!() |> Jason.decode!()}
  end

  defp import_archive(path, target, tmp) do
    Import.run(target, path, operator: "fixtures@example.com", tmp_dir: Path.join(tmp, "import"))
  end

  defp assert_round_trip(target, expected, tmp) do
    returning =
      target
      |> Accounts.scope_for()
      |> Principals.list_unlinked()
      |> Map.new(&{&1.principal.source_id, &1.role})

    # Access a directory managed, and access that was disabled, stay
    # reference data; an active manual member can be invited back.
    assert Map.fetch!(returning, expected["managed_principal"]) == nil
    assert Map.fetch!(returning, expected["former_principal"]) == nil
    assert Map.fetch!(returning, expected["viewer_principal"]) == "viewer"

    # A former actor's shared view stays, attributed to their principal.
    shared = Repo.get!(SavedView, expected["shared_view"])
    assert shared.organization_id == target.id and is_nil(shared.created_by_id)
    assert attributed_to(target, shared.id) == expected["former_principal"]

    # An unclaimed private view waits for its owner, unseen.
    refute Repo.get(SavedView, expected["private_view"])
    assert held_for(target, expected["private_view"]) == expected["viewer_principal"]

    # A queued job is history that never runs.
    assert %Job{state: "queued", imported_at: %DateTime{}} =
             Repo.get!(Job, expected["queued_job"])

    agent = Repo.one!(where(Inventory.Agent, organization_id: ^target.id))

    assert {:ok, []} =
             Jobs.lease_jobs(Accounts.scope_for(target), agent, ["inventory.collect@1"], 9)

    # Evidence came without raw observations, yet every observation it
    # rests on came with it.
    assert Repo.get!(Inventory.Resource, expected["resource"]).organization_id == target.id
    assert missing_observations(target) == 0
    assert claims(target, expected["resource"]) > 0

    again = Path.join(tmp, "again-#{System.unique_integer([:positive])}.tar.zst")
    {:ok, _summary} = Export.write(Repo.get!(Organization, target.id), again, parts: @parts)
    {:ok, archive} = Archive.open(again, tmp_dir: tmp)
    assert :ok = Validation.validate(archive)
    Archive.close(archive)
  end

  defp attributed_to(target, record_id) do
    one(
      "SELECT p.source_id FROM imported_attributions AS a " <>
        "JOIN imported_principals AS p ON p.id = a.principal_id " <>
        "WHERE a.organization_id = $1 AND a.record_type = 'saved_views' " <>
        "AND a.record_id = $2 AND a.field = 'created_by_id'",
      [dump(target.id), dump(record_id)]
    )
  end

  defp held_for(target, record_id) do
    one(
      "SELECT p.source_id FROM imported_held_records AS h " <>
        "JOIN imported_principals AS p ON p.id = h.principal_id " <>
        "WHERE h.organization_id = $1 AND h.record_type = 'saved_views' " <>
        "AND h.record ->> 'id' = $2",
      [dump(target.id), record_id]
    )
  end

  defp missing_observations(target) do
    RecordTypes.observation_references()
    |> Enum.map(fn {type, field} ->
      one(
        "SELECT count(*) FROM #{type} AS r WHERE r.organization_id = $1 " <>
          "AND r.#{field} IS NOT NULL AND NOT EXISTS " <>
          "(SELECT 1 FROM observations AS o WHERE o.id = r.#{field})",
        [dump(target.id)]
      )
    end)
    |> Enum.sum()
  end

  defp claims(target, resource_id) do
    one(
      "SELECT count(*) FROM resource_identifier_claims WHERE organization_id = $1 " <>
        "AND resource_id = $2",
      [dump(target.id), dump(resource_id)]
    )
  end

  defp one(sql, params) do
    %{rows: [[value]]} = Repo.query!(sql, params)
    if is_binary(value) and byte_size(value) == 16, do: Ecto.UUID.load!(value), else: value
  end

  defp dump(id), do: Ecto.UUID.dump!(id)

  defp organization_fixture, do: Renga.InventoryFixtures.organization_fixture()
end
