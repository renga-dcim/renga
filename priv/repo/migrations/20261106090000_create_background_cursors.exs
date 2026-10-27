defmodule Renga.Repo.Migrations.CreateBackgroundCursors do
  use Ecto.Migration

  def change do
    create table(:background_cursors, primary_key: false) do
      add :worker, :text, primary_key: true
      # A deployment cursor may point past a deleted organization; this is
      # not tenant-owned data and deliberately has no organization FK.
      add :last_organization_id, :uuid
    end

    create index(:jobs, [:organization_id, :lease_expires_at],
             where: "state IN ('leased', 'running') AND imported_at IS NULL",
             name: :jobs_organization_lease_sweep
           )

    create index(:jobs, [:organization_id, :not_after],
             where: "state = 'queued' AND imported_at IS NULL",
             name: :jobs_organization_deadline_sweep
           )

    create index(:telemetry_batches, [:organization_id, :received_at])
    create index(:telemetry_buckets, [:organization_id, :bucket_start])
  end
end
