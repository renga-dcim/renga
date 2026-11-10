defmodule Renga.Transfers do
  @moduledoc """
  Organization exports people start from organization settings (RFD 20).

  Exporting covers the whole organization regardless of the exporter's own
  read scope, so every action here requires `organization.export`, checked
  in the transaction that acts, and every action is recorded in Activity:
  starting an export, downloading it, revoking it, and its expiry or
  failure.

  An export runs in the background (`Renga.Transfers.Export`). Its archive
  is stored in the database in chunks, so whichever node serves a download
  can read it, and offered for seven days. Every download rechecks the
  member's permission; an owner can revoke a download early, and
  `sweep/1` deletes the archive once it expires.

  Operators export with `bin/renga-admin export` instead, which writes the
  archive to a file and records it with `record_operator_export/2`.
  """

  import Ecto.Query

  require Logger

  alias Renga.Accounts.Organization
  alias Renga.Accounts.Scope
  alias Renga.Accounts.User
  alias Renga.Accounts.UserNotifier
  alias Renga.Authorization
  alias Renga.DeploymentAudit
  alias Renga.Inventory.ChangeEvent
  alias Renga.Inventory.Changes
  alias Renga.Jobs
  alias Renga.Repo
  alias Renga.Transfers.Archive
  alias Renga.Transfers.Export
  alias Renga.Transfers.OrganizationExport

  @validity_days 7
  @chunk_bytes 1024 * 1024
  # A node that stops mid-export leaves it running; one this old has died.
  @stale_after_hours 24
  @generation_budget_ms 59_000

  @doc "How long an archive is offered for download, in days."
  def validity_days, do: @validity_days

  @doc "Retained archive bytes plus unused running-export reservations."
  def archive_usage(organization_id),
    do: Renga.Quotas.usage(organization_id, :export_archive_bytes)

  @doc "The deployment's declared maximum compressed size for each new export."
  def export_maximum_bytes,
    do: Application.get_env(:renga, __MODULE__, []) |> Keyword.get(:maximum_bytes, 1_073_741_824)

  @doc "The organization's exports, newest first."
  def list_exports(%Scope{} = scope) do
    Repo.transaction(fn ->
      authorize_export!(scope)

      OrganizationExport
      |> where([export], export.organization_id == ^scope.organization_id)
      |> where([export], export.storage == "managed")
      |> order_by([export], desc: export.inserted_at, desc: export.id)
      |> preload([:requested_by_user, :revoked_by_user])
      |> Repo.all()
    end)
  end

  @doc """
  Starts exporting the organization with optional `parts`, then runs the
  export in the background. When the archive is ready, the exporter gets an
  email with the link `url_fun.()` builds.

  Returns `{:error, :already_running}` while another export of the
  organization runs, and `{:error, :forbidden}` without
  `organization.export`.
  """
  def start_export(%Scope{} = scope, parts, url_fun) when is_function(url_fun, 0) do
    parts = Enum.filter(Archive.parts(), &(&1 in parts))

    scope
    |> insert_export(parts, url_fun)
    |> Changes.broadcast(scope.organization_id)
    |> tap(fn
      {:ok, export} -> run_in_background(export, url_fun)
      _error -> :ok
    end)
  end

  defp insert_export(scope, parts, url_fun) do
    Repo.transaction(fn ->
      authorize_export!(scope)

      %OrganizationExport{
        organization_id: scope.organization_id,
        requested_by_user_id: scope.user.id,
        parts: parts,
        readable_payloads: scope |> Jobs.readable_payloads() |> Enum.sort(),
        notification_url: url_fun.(),
        maximum_bytes: export_maximum_bytes(),
        status: "running"
      }
      |> Ecto.Changeset.change()
      |> Renga.Quotas.constrain(:export_archive_bytes)
      |> Ecto.Changeset.unique_constraint(:organization_id,
        name: :organization_exports_one_running
      )
      |> Repo.insert()
      |> case do
        {:ok, export} ->
          record!(export, scope.user.id, "export_started", %{"parts" => parts})
          export

        {:error, changeset} ->
          rollback_export_start(changeset)
      end
    end)
  end

  # Tests run exports inline, inside their SQL sandbox.
  defp run_in_background(export, url_fun) do
    case Application.get_env(:renga, __MODULE__, [])[:run_exports] do
      :inline ->
        run(export.id, url_fun)

      _background ->
        # The durable row is the queue. A request cannot spawn another
        # snapshot task while this node's export reserve is occupied.
        :ok
    end

    :ok
  end

  @doc """
  Generates an operator-owned file with a durable maximum-byte reservation.
  The linked task cannot outlive its caller; a crashed caller leaves the
  existing deadline worker to end the reservation. No managed archive bytes
  remain after generation because the operator owns and deletes the file.
  """
  def write_operator_export(%Organization{} = organization, path, options \\ []) do
    maximum = export_maximum_bytes()

    with {:ok, export} <- insert_operator_export(organization, maximum, options) do
      task =
        Task.async(fn ->
          Renga.UsageTelemetry.put_organization(organization.id)

          try do
            Export.write(organization, path, Keyword.put(options, :maximum_bytes, maximum))
          rescue
            exception -> {:error, Exception.message(exception)}
          end
        end)

      try do
        case Task.yield(task, @generation_budget_ms) || Task.shutdown(task, :brutal_kill) do
          {:ok, {:ok, summary}} ->
            Repo.transaction(fn ->
              lock_organization!(organization.id)
              current = locked_export(organization.id, export.id)
              if current.status != "running", do: Repo.rollback(:not_running)
              check_generation_deadline!(current)
              # There is no download to retain: the completed file is external.
              current
              |> Ecto.Changeset.change(status: "expired", finished_at: Renga.Time.utc_now_ms())
              |> Repo.update!()

              summary
            end)

          {:ok, {:error, reason}} ->
            {:error, reason}

          _timeout ->
            {:error, :generation_timeout}
        end
      after
        fail(export, false)
      end
    end
  end

  defp insert_operator_export(organization, maximum, options) do
    Repo.transaction(fn ->
      lock_organization!(organization.id)

      %OrganizationExport{
        organization_id: organization.id,
        status: "running",
        storage: "operator",
        maximum_bytes: maximum,
        parts: Keyword.get(options, :parts, []),
        processing_deadline: DateTime.add(Renga.Time.utc_now_ms(), 60, :second)
      }
      |> Ecto.Changeset.change()
      |> Renga.Quotas.constrain(:export_archive_bytes)
      |> Ecto.Changeset.unique_constraint(:organization_id,
        name: :organization_exports_one_running
      )
      |> Repo.insert()
      |> case do
        {:ok, export} -> export
        {:error, reason} -> rollback_export_start(reason)
      end
    end)
  end

  defp rollback_export_start(changeset) do
    reason =
      if Renga.Quotas.exceeded?(changeset, :export_archive_bytes),
        do: {:quota_exceeded, :export_archive_bytes},
        else: :already_running

    Repo.rollback(reason)
  end

  @doc false
  # Writes the archive and stores it, unless the export was revoked
  # meanwhile. A failure marks the export failed rather than leaving it
  # running.
  def run(export_id, url_fun, options \\ []) do
    started = System.monotonic_time(:millisecond)
    export = Repo.get!(OrganizationExport, export_id)
    organization = Repo.get!(Organization, export.organization_id)
    # The archive holds the whole organization, so it is written in a new
    # directory only this node's user can read, as the CLI's output is.
    dir =
      Path.join(
        Keyword.get_lazy(options, :tmp_dir, &System.tmp_dir!/0),
        "renga-export-#{Ecto.UUID.generate()}"
      )

    previous_trap_exit = Process.flag(:trap_exit, true)

    try do
      File.mkdir!(dir)
      File.chmod!(dir, 0o700)
      path = Path.join(dir, "#{export.id}.tar.zst")

      # Link cancellation to the owner as well as the ordinary deadline:
      # an outer worker timeout must not leave its snapshot running.
      task =
        Task.Supervisor.async(Renga.Background.Tasks, fn ->
          Renga.UsageTelemetry.with_organization(export.organization_id, fn ->
            {:ok, summary} =
              Export.write(
                organization,
                path,
                Keyword.merge(options,
                  tmp_dir: dir,
                  parts: export.parts,
                  maximum_bytes: export.maximum_bytes,
                  readable_payloads: export.readable_payloads
                )
              )

            case store(export, path, summary) do
              {:ok, export} -> notify_ready(export, organization, url_fun)
              {:error, :not_running} -> :ok
            end
          end)
        end)

      budget =
        max(
          Keyword.get(options, :budget_ms, @generation_budget_ms) -
            (System.monotonic_time(:millisecond) - started),
          0
        )

      case await_snapshot(task, budget) do
        {:ok, _result} ->
          :ok

        result ->
          Logger.error("Organization export #{export.id} failed: #{inspect(result)}")
          fail(export)
      end
    rescue
      exception ->
        Logger.error("Organization export #{export.id} failed: #{Exception.message(exception)}")
        fail(export)
    after
      File.rm_rf(dir)
      Process.flag(:trap_exit, previous_trap_exit)
    end
  end

  # Task.yield ignores linked parent exits while this process traps exits.
  # Cancel the snapshot before unwinding through cleanup and releasing the
  # batch's execution permit, even when its coordinator has been killed.
  defp await_snapshot(task, budget) do
    receive do
      {ref, result} when ref == task.ref ->
        Process.demonitor(ref, [:flush])
        {:ok, result}

      {:DOWN, ref, :process, _pid, reason} when ref == task.ref ->
        {:exit, reason}

      {:EXIT, pid, reason} when pid != task.pid and reason != :normal ->
        Task.shutdown(task, :brutal_kill)
        exit(reason)
    after
      budget -> Task.shutdown(task, :brutal_kill)
    end
  end

  @doc false
  def generate_queued do
    now = Renga.Time.utc_now_ms()

    ready =
      from export in OrganizationExport,
        where: export.status == "running",
        where: is_nil(export.processing_deadline) or export.processing_deadline <= ^now,
        distinct: export.organization_id,
        select: %{organization_id: export.organization_id}

    Renga.Background.run("export_generation", ready, &generate_organization/1,
      budget_ms: 60_000,
      batch_timeout_ms: 60_000,
      max_batches: 1
    )
  end

  defp generate_organization(organization_id) do
    started = System.monotonic_time(:millisecond)

    {:ok, claimed} =
      Repo.transaction(fn ->
        # The same row-before-child order as revocation and lifecycle purge.
        Repo.query!("SELECT id FROM organizations WHERE id = $1 FOR KEY SHARE", [
          Ecto.UUID.dump!(organization_id)
        ])

        export =
          Repo.one(
            from export in OrganizationExport,
              where: export.organization_id == ^organization_id and export.status == "running",
              lock: "FOR UPDATE SKIP LOCKED"
          )

        claim_generation!(export)
      end)

    if claimed do
      url = claimed.notification_url || RengaWeb.Endpoint.url() <> "/settings/export"

      run(claimed.id, fn -> url end,
        budget_ms: max(@generation_budget_ms - (System.monotonic_time(:millisecond) - started), 0)
      )
    end
  end

  defp claim_generation!(%OrganizationExport{processing_deadline: nil} = export) do
    export
    |> Ecto.Changeset.change(
      processing_deadline: DateTime.add(Renga.Time.utc_now_ms(), 60, :second)
    )
    |> Repo.update!()
  end

  defp claim_generation!(%OrganizationExport{} = export) do
    # A claimed snapshot cannot be resumed across a crashed database
    # transaction. Fail it once; never publish or restart a stale claim.
    if DateTime.compare(export.processing_deadline, Renga.Time.utc_now_ms()) != :gt,
      do: mark_failed!(export)

    nil
  end

  defp claim_generation!(nil), do: nil

  defp store(export, path, summary) do
    result =
      Repo.transaction(
        fn ->
          Repo.query!("SELECT id FROM organizations WHERE id = $1 FOR KEY SHARE", [
            Ecto.UUID.dump!(export.organization_id)
          ])

          case locked_export(export.organization_id, export.id) do
            %OrganizationExport{status: "running"} = export ->
              check_generation_deadline!(export)
              {bytes, sha256} = insert_chunks(export, path)
              now = Renga.Time.utc_now_ms()
              check_generation_deadline!(export)

              export
              |> Ecto.Changeset.change(
                status: "ready",
                snapshot_at: summary.snapshot_at,
                records: summary.records,
                bytes: bytes,
                sha256: sha256,
                finished_at: now,
                expires_at: DateTime.add(now, @validity_days, :day)
              )
              |> Repo.update!()

            _revoked ->
              Repo.rollback(:not_running)
          end
        end,
        timeout: @generation_budget_ms
      )

    Changes.broadcast(result, export.organization_id)
  end

  defp check_generation_deadline!(%{processing_deadline: nil}), do: :ok

  defp check_generation_deadline!(%{processing_deadline: deadline}) do
    if DateTime.compare(deadline, Renga.Time.utc_now_ms()) != :gt,
      do: Repo.rollback(:not_running)
  end

  defp insert_chunks(export, path) do
    export_id = Ecto.UUID.dump!(export.id)

    {bytes, hash} =
      path
      |> File.stream!(@chunk_bytes)
      |> Stream.with_index()
      |> Enum.reduce({0, :crypto.hash_init(:sha256)}, fn {data, position}, {bytes, hash} ->
        Repo.query!(
          "INSERT INTO organization_export_chunks (export_id, position, data) VALUES ($1, $2, $3)",
          [export_id, position, data]
        )

        {bytes + byte_size(data), :crypto.hash_update(hash, data)}
      end)

    {bytes, hash |> :crypto.hash_final() |> Base.encode16(case: :lower)}
  end

  defp notify_ready(%OrganizationExport{requested_by_user_id: nil}, _organization, _url_fun),
    do: :ok

  defp notify_ready(export, organization, url_fun) do
    with %User{email: email} <- Repo.get(User, export.requested_by_user_id),
         {:error, reason} <-
           UserNotifier.deliver_export_ready(
             email,
             organization.name,
             export.expires_at,
             url_fun.()
           ) do
      Logger.warning("Could not email that export #{export.id} is ready: #{inspect(reason)}")
    end

    :ok
  end

  defp fail(export, broadcast? \\ true) do
    result =
      Repo.with_statement_timeout(200, fn _options ->
        lock_organization!(export.organization_id)

        case locked_export(export.organization_id, export.id) do
          %OrganizationExport{status: "running"} = export -> mark_failed!(export)
          _other -> :ok
        end
      end)

    # Repo-only CLI commands deliberately start neither PubSub nor endpoints.
    if broadcast?, do: Changes.broadcast(result, export.organization_id)

    :ok
  end

  defp mark_failed!(export) do
    export
    |> Ecto.Changeset.change(status: "failed", finished_at: Renga.Time.utc_now_ms())
    |> Repo.update!()

    record!(export, nil, "export_failed", %{})
    true
  end

  @doc """
  Authorizes downloading export `export_id` now and records the download.
  Returns the export, whose archive `chunks/2` streams, or
  `{:error, :not_found}` once it is no longer offered.
  """
  def authorize_download(%Scope{} = scope, export_id) do
    Repo.transaction(fn ->
      authorize_export!(scope)

      with {:ok, export_id} <- Ecto.UUID.cast(export_id),
           %OrganizationExport{} = export <- locked_export(scope.organization_id, export_id),
           true <- OrganizationExport.downloadable?(export, Renga.Time.utc_now_ms()),
           true <- reads_payloads?(scope, export) do
        record!(export, scope.user.id, "export_downloaded", %{})
        export
      else
        _unavailable -> Repo.rollback(:not_found)
      end
    end)
    |> Changes.broadcast(scope.organization_id)
  end

  @doc """
  Records that a download `authorize_download/2` allowed ended after
  `sent` of the archive's bytes: the client went away, or a revocation or
  expiry deleted the rest. The download itself was recorded when it was
  allowed, before any byte was sent.
  """
  def record_unfinished_download(%Scope{} = scope, %OrganizationExport{} = export, sent) do
    record!(export, scope.user.id, "export_download_unfinished", %{
      "bytes_sent" => sent,
      "bytes" => export.bytes
    })

    Changes.broadcast({:ok, export}, scope.organization_id)
    :ok
  end

  # An archive holds the query payloads its requester could read (RFD 12),
  # so only someone who can read at least those may download it.
  defp reads_payloads?(scope, export),
    do: MapSet.subset?(MapSet.new(export.readable_payloads), Jobs.readable_payloads(scope))

  @doc """
  Streams a ready export's archive, one stored chunk at a time. A chunk
  deleted mid-stream, by revocation or expiry, ends the stream early.
  Suspension or the committed purge boundary also stops further delivery.
  """
  def chunks(%Scope{} = scope, %OrganizationExport{id: id}) do
    export_id = Ecto.UUID.dump!(id)
    organization_id = Ecto.UUID.dump!(scope.organization_id)

    Stream.unfold(0, fn position ->
      result =
        Repo.transaction(fn ->
          # The recovery exception belongs to the current owner, not to the
          # archive. Recheck before every read, including a mid-stream suspension.
          authorize_export!(scope)

          Repo.query!(
            """
            SELECT c.data FROM organization_export_chunks c
            JOIN organization_exports e ON e.id = c.export_id
            JOIN organizations o ON o.id = e.organization_id
            WHERE c.export_id = $1 AND c.position = $2
              AND e.organization_id = $4
              AND o.status IN ('active', 'deletion_pending')
              AND e.status = 'ready' AND e.expires_at > $3
            """,
            [export_id, position, Renga.Time.utc_now_ms(), organization_id]
          )
        end)

      case result do
        {:ok, %{rows: [[data]]}} -> {data, position + 1}
        _unavailable -> nil
      end
    end)
  end

  @doc """
  Revokes a running or ready export: a running one stores nothing, and a
  ready one's archive is deleted at once.
  """
  def revoke_export(%Scope{} = scope, export_id) do
    Repo.transaction(fn ->
      authorize_export!(scope)

      with {:ok, export_id} <- Ecto.UUID.cast(export_id),
           %OrganizationExport{status: status} = export when status in ~w(running ready) <-
             locked_export(scope.organization_id, export_id) do
        delete_chunks!(export)
        record!(export, scope.user.id, "export_revoked", %{})

        export
        |> Ecto.Changeset.change(
          status: "revoked",
          revoked_at: Renga.Time.utc_now_ms(),
          revoked_by_user_id: scope.user.id
        )
        |> Repo.update!()
      else
        _other -> Repo.rollback(:not_found)
      end
    end)
    |> Changes.broadcast(scope.organization_id)
  end

  @doc """
  Expires ready exports whose seven days have passed, deleting their
  archives, and fails exports a stopped node left running. Returns how
  many exports it changed.
  """
  def sweep(now \\ Renga.Time.utc_now_ms()) do
    stale_before = DateTime.add(now, -@stale_after_hours, :hour)

    due =
      OrganizationExport
      |> from(as: :export)
      |> where(
        [export],
        (export.status == "ready" and export.expires_at <= ^now) or
          (export.status == "running" and export.inserted_at <= ^stale_before) or
          (export.status in ~w(expired failed revoked) and
             exists(
               from chunk in "organization_export_chunks",
                 where: chunk.export_id == parent_as(:export).id,
                 select: 1
             ))
      )

    ready =
      from export in due,
        distinct: export.organization_id,
        select: %{organization_id: export.organization_id}

    Renga.Background.run("export_expiry", ready, fn organization_id ->
      due
      |> where([export], export.organization_id == ^organization_id)
      |> order_by([export], asc: export.id)
      |> limit(5)
      |> select([export], export.id)
      |> Repo.all()
      |> Enum.count(&sweep_export(organization_id, &1, now, stale_before))
    end)
    |> Enum.reduce(0, fn
      {:ok, count}, total -> total + count
      _failure, total -> total
    end)
  end

  defp sweep_export(organization_id, export_id, now, stale_before) do
    {:ok, changed?} =
      Repo.transaction(fn ->
        lock_organization!(organization_id)
        export = locked_export(organization_id, export_id)
        changed? = sweep_one(export, now, stale_before)

        if export && (changed? or export.status in ~w(expired failed revoked)),
          do: delete_chunk_batch!(export)

        changed?
      end)

    if changed?, do: Changes.broadcast({:ok, nil}, organization_id)
    changed?
  end

  # Rechecked under the lock: a revocation may have won the race.
  defp sweep_one(%OrganizationExport{status: "ready"} = export, now, _stale_before) do
    DateTime.compare(export.expires_at, now) != :gt and expire!(export)
  end

  defp sweep_one(%OrganizationExport{status: "running"} = export, _now, stale_before) do
    DateTime.compare(export.inserted_at, stale_before) != :gt and mark_failed!(export)
  end

  defp sweep_one(_export, _now, _stale_before), do: false

  defp expire!(export) do
    # Stop downloads atomically; byte reclamation then advances in bounded
    # batches even when an archive is too large for one worker deadline.
    export |> Ecto.Changeset.change(status: "expired") |> Repo.update!()
    record!(export, nil, "export_expired", %{})
    true
  end

  @doc """
  Records an operator's `renga-admin export` in the organization's
  Activity, naming the operator as `limits` changes do.
  """
  def record_operator_export(%Organization{} = organization, context) do
    %ChangeEvent{organization_id: organization.id}
    |> ChangeEvent.changeset(%{
      kind: "exported",
      metadata: %{"operator" => DeploymentAudit.actor_label(context)},
      occurred_at: Renga.Time.utc_now_ms()
    })
    |> Repo.insert!()

    :ok
  end

  # Changes made in the background lock the organization before the
  # export, the order a member's action takes them in
  # (Authorization.authorize!/3). Recording Activity needs a key-share lock
  # on the organization, so the opposite order deadlocks with a revocation.
  # Whatever the organization's status, so cleanup also runs for an
  # inactive one.
  defp lock_organization!(organization_id) do
    Repo.query!("SELECT 1 FROM organizations WHERE id = $1 FOR UPDATE", [
      Ecto.UUID.dump!(organization_id)
    ])
  end

  # Only this permission has a recovery exception: a pending-deletion owner
  # may export without regaining inventory, job, or organization UI access.
  defp authorize_export!(scope) do
    organization =
      Repo.one(from o in Organization, where: o.id == ^scope.organization_id, lock: "FOR UPDATE")

    case organization do
      %Organization{status: "deletion_pending"} ->
        Renga.Operators.OrganizationLifecycle.authorize_export!(scope)

      _ ->
        Authorization.authorize!(scope, "organization.export")
    end
  end

  defp locked_export(organization_id, export_id) do
    OrganizationExport
    |> where([export], export.organization_id == ^organization_id and export.id == ^export_id)
    |> lock("FOR UPDATE")
    |> Repo.one()
  end

  defp delete_chunks!(export) do
    Repo.query!("DELETE FROM organization_export_chunks WHERE export_id = $1", [
      Ecto.UUID.dump!(export.id)
    ])
  end

  defp delete_chunk_batch!(export) do
    Repo.query!(
      """
      DELETE FROM organization_export_chunks WHERE export_id = $1 AND position IN
        (SELECT position FROM organization_export_chunks WHERE export_id = $1
         ORDER BY position LIMIT 25)
      """,
      [Ecto.UUID.dump!(export.id)]
    )
  end

  defp record!(export, actor_user_id, kind, metadata) do
    %ChangeEvent{organization_id: export.organization_id, actor_user_id: actor_user_id}
    |> ChangeEvent.changeset(%{
      kind: kind,
      metadata: Map.put(metadata, "export_id", export.id),
      occurred_at: Renga.Time.utc_now_ms()
    })
    |> Repo.insert!()
  end
end
