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
  alias Renga.Repo
  alias Renga.Transfers.Archive
  alias Renga.Transfers.Export
  alias Renga.Transfers.OrganizationExport

  @validity_days 7
  @chunk_bytes 1024 * 1024
  # A node that stops mid-export leaves it running; one this old has died.
  @stale_after_hours 24

  @doc "How long an archive is offered for download, in days."
  def validity_days, do: @validity_days

  @doc "The organization's exports, newest first."
  def list_exports(%Scope{} = scope) do
    Repo.transaction(fn ->
      Authorization.authorize!(scope, "organization.export")

      OrganizationExport
      |> where([export], export.organization_id == ^scope.organization_id)
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
    |> insert_export(parts)
    |> Changes.broadcast(scope.organization_id)
    |> tap(fn
      {:ok, export} -> run_in_background(export, url_fun)
      _error -> :ok
    end)
  end

  defp insert_export(scope, parts) do
    Repo.transaction(fn ->
      Authorization.authorize!(scope, "organization.export")

      %OrganizationExport{
        organization_id: scope.organization_id,
        requested_by_user_id: scope.user.id,
        parts: parts,
        status: "running"
      }
      |> Ecto.Changeset.change()
      |> Ecto.Changeset.unique_constraint(:organization_id,
        name: :organization_exports_one_running
      )
      |> Repo.insert()
      |> case do
        {:ok, export} ->
          record!(export, scope.user.id, "export_started", %{"parts" => parts})
          export

        {:error, _changeset} ->
          Repo.rollback(:already_running)
      end
    end)
  end

  # Tests run exports inline, inside their SQL sandbox.
  defp run_in_background(export, url_fun) do
    case Application.get_env(:renga, __MODULE__, [])[:run_exports] do
      :inline ->
        run(export.id, url_fun)

      _background ->
        {:ok, _pid} =
          Task.Supervisor.start_child(Renga.Transfers.TaskSupervisor, fn ->
            run(export.id, url_fun)
          end)
    end

    :ok
  end

  @doc false
  # Writes the archive and stores it, unless the export was revoked
  # meanwhile. A failure marks the export failed rather than leaving it
  # running.
  def run(export_id, url_fun) do
    export = Repo.get!(OrganizationExport, export_id)
    organization = Repo.get!(Organization, export.organization_id)
    # The archive holds the whole organization, so it is written in a new
    # directory only this node's user can read, as the CLI's output is.
    dir = Path.join(System.tmp_dir!(), "renga-export-#{Ecto.UUID.generate()}")

    try do
      File.mkdir!(dir)
      File.chmod!(dir, 0o700)
      path = Path.join(dir, "#{export.id}.tar.zst")
      {:ok, summary} = Export.write(organization, path, parts: export.parts)

      case store(export, path, summary) do
        {:ok, export} -> notify_ready(export, organization, url_fun)
        {:error, :not_running} -> :ok
      end
    rescue
      exception ->
        Logger.error("Organization export #{export.id} failed: #{Exception.message(exception)}")
        fail(export)
    after
      File.rm_rf(dir)
    end
  end

  defp store(export, path, summary) do
    result =
      Repo.transaction(
        fn ->
          case locked_export(export.organization_id, export.id) do
            %OrganizationExport{status: "running"} = export ->
              {bytes, sha256} = insert_chunks(export, path)
              now = Renga.Time.utc_now_ms()

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
        timeout: :infinity
      )

    Changes.broadcast(result, export.organization_id)
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

  defp fail(export) do
    Repo.transaction(fn ->
      case locked_export(export.organization_id, export.id) do
        %OrganizationExport{status: "running"} = export -> mark_failed!(export)
        _other -> :ok
      end
    end)
    |> Changes.broadcast(export.organization_id)

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
  Returns the export, whose archive `chunks/1` streams, or
  `{:error, :not_found}` once it is no longer offered.
  """
  def authorize_download(%Scope{} = scope, export_id) do
    Repo.transaction(fn ->
      Authorization.authorize!(scope, "organization.export")

      with {:ok, export_id} <- Ecto.UUID.cast(export_id),
           %OrganizationExport{} = export <- locked_export(scope.organization_id, export_id),
           true <- OrganizationExport.downloadable?(export, Renga.Time.utc_now_ms()) do
        record!(export, scope.user.id, "export_downloaded", %{})
        export
      else
        _unavailable -> Repo.rollback(:not_found)
      end
    end)
    |> Changes.broadcast(scope.organization_id)
  end

  @doc """
  Streams a ready export's archive, one stored chunk at a time. A chunk
  deleted mid-stream, by revocation or expiry, ends the stream early.
  """
  def chunks(%OrganizationExport{id: id}) do
    export_id = Ecto.UUID.dump!(id)

    Stream.unfold(0, fn position ->
      case Repo.query!(
             "SELECT data FROM organization_export_chunks WHERE export_id = $1 AND position = $2",
             [export_id, position]
           ) do
        %{rows: [[data]]} -> {data, position + 1}
        %{rows: []} -> nil
      end
    end)
  end

  @doc """
  Revokes a running or ready export: a running one stores nothing, and a
  ready one's archive is deleted at once.
  """
  def revoke_export(%Scope{} = scope, export_id) do
    Repo.transaction(fn ->
      Authorization.authorize!(scope, "organization.export")

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
      |> where(
        [export],
        (export.status == "ready" and export.expires_at <= ^now) or
          (export.status == "running" and export.inserted_at <= ^stale_before)
      )
      |> select([export], {export.organization_id, export.id})
      |> Repo.all()

    Enum.count(due, fn {organization_id, export_id} ->
      {:ok, changed?} =
        Repo.transaction(fn ->
          organization_id |> locked_export(export_id) |> sweep_one(now, stale_before)
        end)

      if changed?, do: Changes.broadcast({:ok, nil}, organization_id)
      changed?
    end)
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
    delete_chunks!(export)
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
