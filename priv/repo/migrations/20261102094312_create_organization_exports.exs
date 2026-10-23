defmodule Renga.Repo.Migrations.CreateOrganizationExports do
  use Ecto.Migration

  # RFD 20: an owner's organization export and its archive. The archive is
  # stored in the database, in chunks, so any node can serve a download and
  # nothing outlives the export's seven days on a node's disk.
  def change do
    create table(:organization_exports) do
      add :organization_id, references(:organizations, on_delete: :delete_all), null: false
      add :requested_by_user_id, references(:users, on_delete: :nilify_all)
      add :parts, {:array, :string}, null: false, default: []
      # The query payloads its requester could read when it started (RFD 12).
      add :readable_payloads, {:array, :string}, null: false, default: []
      add :status, :string, null: false
      add :snapshot_at, :"timestamp(3)"
      add :records, :bigint
      add :bytes, :bigint
      add :sha256, :string
      add :finished_at, :"timestamp(3)"
      add :expires_at, :"timestamp(3)"
      add :revoked_at, :"timestamp(3)"
      add :revoked_by_user_id, references(:users, on_delete: :nilify_all)

      timestamps(type: :"timestamp(3)")
    end

    create index(:organization_exports, [:organization_id, :inserted_at])
    create index(:organization_exports, [:status, :expires_at])

    # One export runs at a time per organization.
    create unique_index(:organization_exports, [:organization_id],
             where: "status = 'running'",
             name: :organization_exports_one_running
           )

    create constraint(:organization_exports, :valid_status,
             check: "status IN ('running', 'ready', 'failed', 'revoked', 'expired')"
           )

    create table(:organization_export_chunks, primary_key: false) do
      add :export_id, references(:organization_exports, on_delete: :delete_all), primary_key: true

      add :position, :integer, primary_key: true
      add :data, :binary, null: false
    end
  end
end
