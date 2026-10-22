defmodule Renga.TransfersTest do
  use Renga.DataCase, async: true

  import Renga.JobsFixtures
  import ExUnit.CaptureLog

  alias Renga.Accounts.OrganizationMembership
  alias Renga.Inventory.ChangeEvent
  alias Renga.Transfers
  alias Renga.Transfers.Archive
  alias Renga.Transfers.OrganizationExport

  @moduletag :tmp_dir

  setup do
    %{organization: organization, scope: owner} = job_organization_fixture()
    agent = agent_fixture(organization)
    reported_resource_fixture(organization, agent)
    %{organization: organization, owner: owner}
  end

  defp url, do: "https://renga.test/settings/export"

  defp start!(scope, parts \\ []) do
    assert {:ok, export} = Transfers.start_export(scope, parts, &url/0)
    Repo.get!(OrganizationExport, export.id)
  end

  defp activity(organization) do
    ChangeEvent
    |> where([event], event.organization_id == ^organization.id)
    |> where([event], like(event.kind, "export%"))
    |> order_by([event], asc: event.inserted_at, asc: event.id)
    |> select([event], {event.kind, event.actor_user_id})
    |> Repo.all()
  end

  defp chunk_count(export) do
    %{rows: [[count]]} =
      Repo.query!("SELECT count(*) FROM organization_export_chunks WHERE export_id = $1", [
        Ecto.UUID.dump!(export.id)
      ])

    count
  end

  test "an owner's export runs, stores its archive, and emails that it is ready", context do
    %{owner: owner, organization: organization, tmp_dir: tmp} = context

    export = start!(owner, ["history", "everything"])

    assert %OrganizationExport{status: "ready", parts: ["history"]} = export
    assert export.requested_by_user_id == owner.user.id
    assert export.records > 0
    assert DateTime.diff(export.expires_at, export.finished_at, :day) == 7

    path = Path.join(tmp, "download.tar.zst")
    assert {:ok, download} = Transfers.authorize_download(owner, export.id)
    File.write!(path, Enum.to_list(Transfers.chunks(download)))

    assert File.stat!(path).size == export.bytes

    assert :sha256 |> :crypto.hash(File.read!(path)) |> Base.encode16(case: :lower) ==
             export.sha256

    assert {:ok, archive} = Archive.open(path, tmp_dir: tmp)
    assert archive.manifest["organization"]["id"] == organization.id
    assert archive.manifest["parts"] == ["history"]
    Archive.close(archive)

    subject = "Your export of #{organization.name} is ready"
    assert_received {:email, %{subject: ^subject} = email}
    assert email.to == [{"", owner.user.email}]
    assert email.text_body =~ url()

    assert activity(organization) == [
             {"export_started", owner.user.id},
             {"export_downloaded", owner.user.id}
           ]

    assert [%OrganizationExport{id: id}] = elem(Transfers.list_exports(owner), 1)
    assert id == export.id
  end

  test "every action requires organization.export, checked when it happens", context do
    %{owner: owner, organization: organization} = context
    admin = member_scope(organization, "admin")

    assert {:error, :forbidden} = Transfers.start_export(admin, [], &url/0)
    assert {:error, :forbidden} = Transfers.list_exports(admin)

    export = start!(owner)
    assert {:error, :forbidden} = Transfers.authorize_download(admin, export.id)
    assert {:error, :forbidden} = Transfers.revoke_export(admin, export.id)

    # The owner who started it loses the role; the link stops working.
    OrganizationMembership
    |> where([m], m.organization_id == ^organization.id and m.user_id == ^owner.user.id)
    |> Repo.update_all(set: [role: "admin"])

    assert {:error, :forbidden} = Transfers.authorize_download(owner, export.id)
    assert activity(organization) == [{"export_started", owner.user.id}]
  end

  test "one export runs at a time", %{owner: owner, organization: organization} do
    Repo.insert!(%OrganizationExport{organization_id: organization.id, status: "running"})
    assert {:error, :already_running} = Transfers.start_export(owner, [], &url/0)
  end

  test "revoking deletes the archive and ends downloads", %{owner: owner} = context do
    export = start!(owner)
    assert chunk_count(export) > 0

    assert {:ok, %OrganizationExport{status: "revoked"} = revoked} =
             Transfers.revoke_export(owner, export.id)

    assert revoked.revoked_by_user_id == owner.user.id
    assert chunk_count(export) == 0
    assert {:error, :not_found} = Transfers.authorize_download(owner, export.id)
    assert {:error, :not_found} = Transfers.revoke_export(owner, export.id)

    assert activity(context.organization) == [
             {"export_started", owner.user.id},
             {"export_revoked", owner.user.id}
           ]
  end

  test "an export revoked while it runs stores nothing", %{owner: owner, organization: org} do
    export =
      Repo.insert!(%OrganizationExport{
        organization_id: org.id,
        requested_by_user_id: owner.user.id,
        status: "running"
      })

    assert {:ok, _revoked} = Transfers.revoke_export(owner, export.id)
    assert :ok = Transfers.run(export.id, &url/0)

    assert %OrganizationExport{status: "revoked", bytes: nil} =
             Repo.get!(OrganizationExport, export.id)

    assert chunk_count(export) == 0
    refute_received {:email, %{subject: "Your export of " <> _}}
  end

  test "an export that raises is marked failed", %{organization: organization} do
    export =
      Repo.insert!(%OrganizationExport{
        organization_id: organization.id,
        status: "running",
        parts: ["not-a-part"]
      })

    assert capture_log(fn -> assert :ok = Transfers.run(export.id, &url/0) end) =~
             "unknown export parts"

    assert %OrganizationExport{status: "failed"} = Repo.get!(OrganizationExport, export.id)
    assert activity(organization) == [{"export_failed", nil}]
  end

  test "the sweep expires archives after seven days and fails abandoned exports", context do
    %{owner: owner, organization: organization} = context
    export = start!(owner)
    assert Transfers.sweep(DateTime.add(export.expires_at, -1, :second)) == 0

    abandoned =
      Repo.insert!(%OrganizationExport{organization_id: organization.id, status: "running"})

    later = DateTime.add(export.expires_at, 1, :second)
    assert Transfers.sweep(later) == 2

    assert %OrganizationExport{status: "expired"} = Repo.get!(OrganizationExport, export.id)
    assert %OrganizationExport{status: "failed"} = Repo.get!(OrganizationExport, abandoned.id)
    assert chunk_count(export) == 0
    assert {:error, :not_found} = Transfers.authorize_download(owner, export.id)
    assert Transfers.sweep(later) == 0

    assert Enum.sort(activity(organization)) ==
             Enum.sort([
               {"export_started", owner.user.id},
               {"export_expired", nil},
               {"export_failed", nil}
             ])
  end

  test "download IDs from another organization are not found", %{owner: owner} do
    other = job_organization_fixture()
    export = start!(other.scope)

    assert {:error, :not_found} = Transfers.authorize_download(owner, export.id)
    assert {:error, :not_found} = Transfers.authorize_download(owner, "not-a-uuid")
    assert {:error, :not_found} = Transfers.revoke_export(owner, export.id)
  end

  test "Activity describes each export action" do
    describe = &RengaWeb.ChangeDescription.describe/1

    assert describe.(%{kind: "export_started", metadata: %{"parts" => []}}) ==
             "Started an organization export"

    assert describe.(%{
             kind: "export_started",
             metadata: %{"parts" => ["history", "raw_observations"]}
           }) ==
             "Started an organization export with history and all raw observations"

    assert describe.(%{kind: "export_downloaded", metadata: %{}}) ==
             "Downloaded an organization export"

    assert describe.(%{kind: "export_expired", metadata: %{}}) ==
             "An organization export expired and was deleted"

    assert describe.(%{kind: "exported", metadata: %{}}) == "Exported the organization"
  end
end
