defmodule Renga.Transfers.ExportConcurrencyTest do
  # Outside the SQL sandbox, so the export can take its own repeatable-read
  # snapshot while another connection commits writes.
  use ExUnit.Case, async: false

  alias Ecto.Adapters.SQL.Sandbox
  alias Renga.Accounts
  alias Renga.Inventory
  alias Renga.Repo
  alias Renga.Transfers.Archive
  alias Renga.Transfers.Export
  alias Renga.Transfers.RecordTypes

  @moduletag :tmp_dir

  setup do
    previous = Application.get_env(:renga, Export)
    on_exit(fn -> Application.put_env(:renga, Export, previous) end)
    :ok
  end

  test "writes that commit during an export do not reach the archive", %{tmp_dir: tmp} do
    with_organization(fn scope, resource ->
      Application.put_env(:renga, Export, repeatable_read: true)
      archive = export_while_writing(scope, resource, tmp)

      assert [%{"name" => "before-export"}] = records(archive, "resources")
      assert Archive.records(archive, "sources") |> Enum.to_list() == []
    end)
  end

  # Without the snapshot, the same interleaving tears the archive, which
  # shows the test above can tell the difference.
  test "without the snapshot, the same writes would reach it", %{tmp_dir: tmp} do
    with_organization(fn scope, resource ->
      Application.put_env(:renga, Export, repeatable_read: false)
      archive = export_while_writing(scope, resource, tmp)

      names = archive |> records("resources") |> Enum.map(& &1["name"]) |> Enum.sort()
      assert names == ["after-export", "during-export"]
    end)
  end

  # Starts an export and, once its snapshot is taken and the first record
  # type written, commits a rename and a new resource from another
  # connection before the export reads resources.
  defp export_while_writing(scope, resource, tmp) do
    path = Path.join(tmp, "export-#{System.unique_integer([:positive])}.tar.zst")
    first_type = hd(RecordTypes.all()).name

    write = fn
      ^first_type ->
        Task.async(fn ->
          :ok = Sandbox.checkout(Repo, sandbox: false)

          try do
            {:ok, _resource} = Inventory.update_resource(scope, resource, %{name: "after-export"})

            {:ok, _resource} =
              Inventory.create_resource(scope, %{kind: "server", name: "during-export"})

            {:ok, _source} = Inventory.create_source(scope, %{kind: "manual", name: "late"})
          after
            Sandbox.checkin(Repo)
          end
        end)
        |> Task.await()

      _type ->
        :ok
    end

    {:ok, _summary} =
      Export.write(Repo.get!(Accounts.Organization, scope.organization_id), path,
        after_record_type: write
      )

    {:ok, archive} = Archive.open(path, tmp_dir: tmp)
    archive
  end

  defp records(archive, type), do: archive |> Archive.records(type) |> Enum.to_list()

  defp with_organization(fun) do
    :ok = Sandbox.checkout(Repo, sandbox: false)

    {:ok, organization} =
      Accounts.create_organization(%{
        name: "Concurrent Export",
        slug: "concurrent-export-#{System.unique_integer([:positive])}"
      })

    scope = Accounts.scope_for(organization)

    try do
      {:ok, resource} =
        Inventory.create_resource(scope, %{kind: "server", name: "before-export"})

      fun.(scope, resource)
    after
      Repo.delete!(organization)
      Sandbox.checkin(Repo)
    end
  end
end
