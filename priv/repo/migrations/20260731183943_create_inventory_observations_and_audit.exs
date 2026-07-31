defmodule Renga.Repo.Migrations.CreateInventoryObservationsAndAudit do
  use Ecto.Migration

  def change do
    create table(:sync_runs, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :organization_id, references(:organizations, on_delete: :delete_all, type: :binary_id),
        null: false

      add :source_id, references(:sources, on_delete: :nilify_all, type: :binary_id)
      add :status, :string, null: false, default: "running"
      add :started_at, :utc_datetime, null: false
      add :completed_at, :utc_datetime
      add :resource_count, :integer, null: false, default: 0
      add :error_count, :integer, null: false, default: 0
      add :metadata, :map, null: false, default: %{}

      timestamps(type: :utc_datetime)
    end

    create index(:sync_runs, [:organization_id, :source_id])
    create index(:sync_runs, [:organization_id, :status])
    create index(:sync_runs, [:organization_id, :started_at])

    create table(:observations, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :organization_id, references(:organizations, on_delete: :delete_all, type: :binary_id),
        null: false

      add :source_id, references(:sources, on_delete: :nilify_all, type: :binary_id)
      add :sync_run_id, references(:sync_runs, on_delete: :nilify_all, type: :binary_id)
      add :resource_id, references(:resources, on_delete: :nilify_all, type: :binary_id)
      add :observation_id, :string
      add :observed_at, :utc_datetime, null: false
      add :status, :string, null: false, default: "accepted"
      add :payload_digest, :binary, null: false
      add :payload, :map, null: false
      add :errors, :map, null: false, default: %{}
      add :metadata, :map, null: false, default: %{}

      timestamps(type: :utc_datetime, updated_at: false)
    end

    create index(:observations, [:organization_id, :source_id])
    create index(:observations, [:organization_id, :sync_run_id])
    create index(:observations, [:organization_id, :resource_id])
    create index(:observations, [:organization_id, :observed_at])

    create unique_index(:observations, [:organization_id, :source_id, :observation_id],
             where: "source_id IS NOT NULL AND observation_id IS NOT NULL"
           )

    create unique_index(:observations, [:organization_id, :source_id, :payload_digest],
             where: "source_id IS NOT NULL"
           )

    create table(:change_events, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :organization_id, references(:organizations, on_delete: :delete_all, type: :binary_id),
        null: false

      add :resource_id, references(:resources, on_delete: :nilify_all, type: :binary_id)
      add :source_id, references(:sources, on_delete: :nilify_all, type: :binary_id)
      add :sync_run_id, references(:sync_runs, on_delete: :nilify_all, type: :binary_id)
      add :observation_id, references(:observations, on_delete: :nilify_all, type: :binary_id)
      add :kind, :string, null: false
      add :field, :string
      add :old_value, :map
      add :new_value, :map
      add :metadata, :map, null: false, default: %{}
      add :occurred_at, :utc_datetime, null: false

      timestamps(type: :utc_datetime)
    end

    create index(:change_events, [:organization_id, :resource_id])
    create index(:change_events, [:organization_id, :source_id])
    create index(:change_events, [:organization_id, :sync_run_id])
    create index(:change_events, [:organization_id, :kind])
    create index(:change_events, [:organization_id, :occurred_at])
  end
end
