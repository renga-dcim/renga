defmodule Renga.TransfersTest do
  use Renga.DataCase, async: false

  import Renga.JobsFixtures
  import ExUnit.CaptureLog

  alias Renga.Accounts
  alias Renga.Accounts.OrganizationMembership
  alias Renga.Assignments
  alias Renga.Inventory.ChangeEvent
  alias Renga.Jobs
  alias Renga.Roles
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
    File.write!(path, Enum.to_list(Transfers.chunks(owner, download)))

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

  test "streaming stops at suspension or purge but permits the pending owner recovery window",
       context do
    export = start!(context.owner)
    lifecycle = Renga.Operators.OrganizationLifecycle
    actor = Renga.DeploymentAudit.operator("stream-containment")
    assert Enum.to_list(Transfers.chunks(context.owner, export)) != []

    {:ok, _} = lifecycle.change(context.organization.id, "suspend", actor)
    assert Enum.to_list(Transfers.chunks(context.owner, export)) == []

    {:ok, organization} = lifecycle.change(context.organization.id, "schedule_deletion", actor)
    assert Enum.to_list(Transfers.chunks(context.owner, export)) != []
    organization |> Ecto.Changeset.change(status: "purging") |> Repo.update!()
    assert Enum.to_list(Transfers.chunks(context.owner, export)) == []
    assert chunk_count(export) > 0
  end

  test "between-chunk deletion and owner revocation stop unauthorized delivery", context do
    member = member_scope(context.organization, "member")

    {:ok, role} =
      Roles.create_role(context.owner, %{
        "name" => "Export delegate",
        "permissions" => ["organization.export"]
      })

    {:ok, _} = Assignments.assign(context.owner, member.membership_id, %{"role" => role.id})
    member = Accounts.scope_for_user(member.user, context.organization.id)
    export = start!(context.owner)
    {:ok, _} = Transfers.authorize_download(member, export.id)
    # Two deterministic chunks expose the exact mid-delivery boundary.
    id = Ecto.UUID.dump!(export.id)
    Repo.query!("DELETE FROM organization_export_chunks WHERE export_id = $1", [id])

    Repo.query!(
      "INSERT INTO organization_export_chunks (export_id, position, data) VALUES ($1, 0, $2), ($1, 1, $3)",
      [id, "first", "second"]
    )

    actor = Renga.DeploymentAudit.operator("stream-boundary")
    lifecycle = Renga.Operators.OrganizationLifecycle

    assert ["first"] ==
             Enum.map(Transfers.chunks(member, export), fn chunk ->
               {:ok, _} = lifecycle.change(context.organization.id, "schedule_deletion", actor)
               chunk
             end)

    assert ["first"] ==
             Enum.map(Transfers.chunks(context.owner, export), fn chunk ->
               Repo.update_all(
                 from(m in OrganizationMembership, where: m.id == ^context.owner.membership_id),
                 set: [role: "member"]
               )

               chunk
             end)

    assert chunk_count(export) == 2
  end

  describe "query payloads (RFD 12)" do
    @packages "query.packages@1"

    # A member allowed sensitive queries ran query.packages; the owner holds
    # no query permission.
    setup %{organization: organization, owner: owner} do
      agent = agent_fixture(organization, ["host.inventory", @packages])
      resource = reported_resource_fixture(organization, agent, "db-01")
      {:ok, _} = Jobs.update_settings(owner, %{allowed_capabilities: [@packages]})

      member = member_scope(organization, "member")
      grant(owner, member, ~w(queries.run queries.run_sensitive))
      requester = Accounts.scope_for_user(member.user, organization.id)
      system = Accounts.scope_for(organization)

      {:ok, job} =
        Jobs.create_job(requester, agent.id, @packages, %{"name" => "ssl"},
          resource_id: resource.id
        )

      {:ok, [{_job, token}]} = Jobs.lease_jobs(system, agent, [@packages], 1)

      {:ok, _} =
        Jobs.report(system, agent, job.id, token, "succeeded", %{
          "result" => %{"packages" => [], "truncated" => false}
        })

      %{job: job}
    end

    defp grant(owner, scope, permissions) do
      {:ok, role} =
        Roles.create_role(owner, %{
          "name" => "Queries #{System.unique_integer([:positive])}",
          "permissions" => permissions
        })

      {:ok, _} = Assignments.assign(owner, scope.membership_id, %{"role" => role.id})
      Accounts.scope_for_user(scope.user, scope.organization_id)
    end

    defp archived_job(scope, export, tmp, job) do
      path = Path.join(tmp, "#{export.id}.tar.zst")
      assert {:ok, download} = Transfers.authorize_download(scope, export.id)
      File.write!(path, Enum.to_list(Transfers.chunks(scope, download)))
      assert {:ok, archive} = Archive.open(path, tmp_dir: tmp)
      on_exit(fn -> Archive.close(archive) end)

      record = archive |> Archive.records("jobs") |> Enum.find(&(&1["id"] == job.id))

      reports =
        for event <- Archive.records(archive, "job_events"),
            event["job_id"] == job.id and event["actor_type"] == "agent",
            do: event["payload"]

      {record, reports}
    end

    test "an export withholds the payloads its requester may not read", context do
      export = start!(context.owner, ["history"])
      {job, reports} = archived_job(context.owner, export, context.tmp_dir, context.job)

      assert %{"parameters" => %{}, "result" => nil, "capability" => "query.packages"} = job
      assert reports != [] and Enum.all?(reports, &(&1 == %{}))
    end

    test "only those who read its payloads download an export that holds them", context do
      owner = grant(context.owner, context.owner, ~w(queries.run queries.run_sensitive))
      export = start!(owner, ["history"])

      {job, reports} = archived_job(owner, export, context.tmp_dir, context.job)
      assert job["parameters"] == %{"name" => "ssl"}
      assert job["result"] == %{"packages" => [], "truncated" => false}
      assert Enum.any?(reports, &(&1 != %{}))

      other_owner = member_scope(context.organization, "owner")
      assert {:error, :not_found} = Transfers.authorize_download(other_owner, export.id)
    end
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

  test "archive capacity is reserved before generation and retained until deletion", %{
    owner: owner,
    organization: organization
  } do
    context = Renga.DeploymentAudit.operator("test")
    maximum = Transfers.export_maximum_bytes()
    :ok = Renga.Limits.set(organization, [export_archive_bytes: maximum - 1], context)

    assert {:error, {:quota_exceeded, :export_archive_bytes}} =
             Transfers.start_export(owner, [], &url/0)

    assert Transfers.archive_usage(organization.id) == 0
    assert Repo.aggregate(OrganizationExport, :count) == 0

    :ok = Renga.Limits.set(organization, [export_archive_bytes: maximum], context)
    export = start!(owner)
    assert export.maximum_bytes == maximum
    assert Transfers.archive_usage(organization.id) == export.bytes
    assert export.bytes > 0 and export.bytes < maximum

    # A lowered quota cannot delete an archive, but cannot fund a new one.
    :ok = Renga.Limits.set(organization, [export_archive_bytes: 0], context)
    assert {:ok, _} = Transfers.authorize_download(owner, export.id)

    assert {:error, {:quota_exceeded, :export_archive_bytes}} =
             Transfers.start_export(owner, [], &url/0)

    assert {:ok, _} = Transfers.revoke_export(owner, export.id)
    assert Transfers.archive_usage(organization.id) == 0
  end

  test "an in-flight reservation survives a lowered limit and only terminal cleanup releases it",
       %{owner: owner, organization: organization} do
    maximum = Transfers.export_maximum_bytes()

    export =
      Repo.insert!(%OrganizationExport{
        organization_id: organization.id,
        requested_by_user_id: owner.user.id,
        status: "running",
        maximum_bytes: maximum
      })

    assert Transfers.archive_usage(organization.id) == maximum

    :ok =
      Renga.Limits.set(
        organization,
        [export_archive_bytes: 0],
        Renga.DeploymentAudit.operator("test")
      )

    assert :ok = Transfers.run(export.id, &url/0)
    ready = Repo.reload!(export)
    assert ready.status == "ready"
    assert Transfers.archive_usage(organization.id) == ready.bytes
    assert Transfers.sweep(DateTime.add(ready.expires_at, 1)) == 1
    assert Transfers.archive_usage(organization.id) == 0
    assert Transfers.sweep(DateTime.add(ready.expires_at, 1)) == 0
  end

  test "exceeding a declared maximum fails without retaining unreserved bytes", %{
    organization: organization
  } do
    export =
      Repo.insert!(%OrganizationExport{
        organization_id: organization.id,
        status: "running",
        maximum_bytes: 1
      })

    assert capture_log(fn -> Transfers.run(export.id, &url/0) end) =~ "reserved maximum"
    assert Repo.reload!(export).status == "failed"
    assert chunk_count(export) == 0
    assert Transfers.archive_usage(organization.id) == 0
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

  test "generation reserve and persisted rotation keep a failed export from delaying its neighbor",
       %{organization: organization} do
    other = Renga.InventoryFixtures.organization_fixture()
    [noisy, quiet] = Enum.sort_by([organization, other], & &1.id)

    bad =
      Repo.insert!(%OrganizationExport{
        organization_id: noisy.id,
        status: "running",
        parts: ["invalid"]
      })

    good = Repo.insert!(%OrganizationExport{organization_id: quiet.id, status: "running"})

    handler = "export-database-#{Ecto.UUID.generate()}"

    :telemetry.attach(
      handler,
      [:renga, :repo, :query],
      fn _, _, metadata, pid ->
        query = metadata.query

        kind =
          cond do
            String.contains?(query, "jsonb_build_object") -> :snapshot
            String.contains?(query, "INSERT INTO organization_export_chunks") -> :chunks
            true -> nil
          end

        if kind, do: send(pid, {:export_database, Renga.UsageTelemetry.organization_id(), kind})
      end,
      self()
    )

    on_exit(fn -> :telemetry.detach(handler) end)

    Repo.query!("DELETE FROM background_cursors WHERE worker = 'export_generation'")
    {:ok, reserve} = Renga.IntakeCapacity.acquire(:export_background, 1)
    assert Transfers.generate_queued() == []
    assert Repo.reload!(bad).processing_deadline == nil
    assert Repo.reload!(good).processing_deadline == nil
    Renga.IntakeCapacity.release(reserve)

    {:ok, general} = Renga.IntakeCapacity.acquire(:background, 1)

    try do
      capture_log(fn -> Transfers.generate_queued() end)
      assert Repo.reload!(bad).status == "failed"
      assert Repo.reload!(good).status == "running"

      Transfers.generate_queued()
      assert Repo.reload!(good).status == "ready"
      assert chunk_count(good) > 0
      quiet_id = quiet.id
      assert_receive {:export_database, ^quiet_id, :snapshot}
      assert_receive {:export_database, ^quiet_id, :chunks}
    after
      Renga.IntakeCapacity.release(general)
    end
  end

  test "a crashed snapshot claim fails once instead of restarting or publishing", %{
    organization: organization
  } do
    export =
      Repo.insert!(%OrganizationExport{
        organization_id: organization.id,
        status: "running",
        processing_deadline: DateTime.add(Renga.Time.utc_now_ms(), -1, :second)
      })

    Transfers.generate_queued()
    assert Repo.reload!(export).status == "failed"
    assert chunk_count(export) == 0
    assert Transfers.generate_queued() == []
    assert activity(organization) == [{"export_failed", nil}]
  end

  test "operator generation competes for archive bytes and releases failed or crashed reservations",
       %{
         organization: organization,
         owner: owner,
         tmp_dir: tmp
       } do
    export = start!(owner)
    maximum = Transfers.export_maximum_bytes()
    context = Renga.DeploymentAudit.operator("operator-export")
    :ok = Renga.Limits.set(organization, [export_archive_bytes: maximum], context)
    path = Path.join(tmp, "operator.tar.zst")

    assert {:error, {:quota_exceeded, :export_archive_bytes}} =
             Transfers.write_operator_export(organization, path)

    assert {:ok, _} = Transfers.revoke_export(owner, export.id)

    assert {:error, _} = Transfers.write_operator_export(organization, path, parts: ["invalid"])
    assert Transfers.archive_usage(organization.id) == 0
    assert {:ok, _} = Transfers.write_operator_export(organization, path)
    assert Transfers.archive_usage(organization.id) == 0
    assert File.stat!(path).size > 0
    assert {:ok, managed} = Transfers.list_exports(owner)
    assert Enum.all?(managed, &(&1.storage == "managed"))

    crashed =
      Repo.insert!(%OrganizationExport{
        organization_id: organization.id,
        status: "running",
        storage: "operator",
        maximum_bytes: maximum,
        processing_deadline: DateTime.add(Renga.Time.utc_now_ms(), -1)
      })

    assert Transfers.archive_usage(organization.id) == maximum
    Transfers.generate_queued()
    assert Repo.reload!(crashed).status == "failed"
    assert Transfers.archive_usage(organization.id) == 0
  end

  test "the sweep expires archives after seven days and fails abandoned exports", context do
    %{owner: owner, organization: organization} = context
    export = start!(owner)
    assert Transfers.sweep(DateTime.add(export.expires_at, -1, :second)) == 0

    abandoned =
      Repo.insert!(%OrganizationExport{organization_id: organization.id, status: "running"})

    # More than one reclamation batch: expiration must revoke the complete
    # archive at once, without having to delete all its bytes in that turn.
    before = chunk_count(export)

    Repo.query!(
      """
      INSERT INTO organization_export_chunks(export_id, position, data)
      SELECT $1, position, 'remaining bytes'::bytea FROM generate_series(1000, 1025) position
      """,
      [Ecto.UUID.dump!(export.id)]
    )

    later = DateTime.add(export.expires_at, 1, :second)
    assert Transfers.sweep(later) == 2

    assert %OrganizationExport{status: "expired"} = Repo.get!(OrganizationExport, export.id)
    assert %OrganizationExport{status: "failed"} = Repo.get!(OrganizationExport, abandoned.id)
    assert chunk_count(export) == before + 1
    assert {:error, :not_found} = Transfers.authorize_download(owner, export.id)
    assert Transfers.sweep(later) == 0
    assert chunk_count(export) == 0

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

    assert describe.(%{kind: "export_download_unfinished", metadata: %{}}) ==
             "A download of an organization export did not finish"

    assert describe.(%{kind: "export_expired", metadata: %{}}) ==
             "An organization export expired and was deleted"

    assert describe.(%{kind: "exported", metadata: %{}}) == "Exported the organization"
  end
end
