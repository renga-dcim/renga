defmodule Renga.Repo.Migrations.CreateInventoryObservationsAndAudit do
  use Ecto.Migration

  def change do
    create table(:sync_runs, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :organization_id, references(:organizations, on_delete: :delete_all, type: :binary_id),
        null: false

      add :source_id, references(:sources, on_delete: :nilify_all, type: :binary_id)
      add :status, :string, null: false, default: "running"
      add :started_at, :"timestamp(3)", null: false
      add :completed_at, :"timestamp(3)"
      add :resource_count, :integer, null: false, default: 0
      add :error_count, :integer, null: false, default: 0
      add :metadata, :map, null: false, default: %{}

      timestamps(type: :"timestamp(3)")
    end

    create index(:sync_runs, [:organization_id, :source_id])
    create index(:sync_runs, [:organization_id, :status])
    create index(:sync_runs, [:organization_id, :started_at])

    create table(:observations, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :organization_id, references(:organizations, on_delete: :delete_all, type: :binary_id),
        null: false

      add :source_id, references(:sources, on_delete: :restrict, type: :binary_id), null: false
      add :sync_run_id, references(:sync_runs, on_delete: :nilify_all, type: :binary_id)
      add :idempotency_key, :string, null: false
      add :observed_at, :"timestamp(3)", null: false
      add :payload_digest, :binary, null: false
      add :payload, :map, null: false

      timestamps(type: :"timestamp(3)", updated_at: false)
    end

    create index(:observations, [:organization_id, :source_id])
    create index(:observations, [:organization_id, :sync_run_id])
    create index(:observations, [:organization_id, :observed_at])

    create unique_index(:observations, [:organization_id, :source_id, :idempotency_key])

    execute """
            CREATE FUNCTION reject_observation_update() RETURNS trigger AS $$
            BEGIN
              RAISE EXCEPTION 'observations are immutable'
                USING ERRCODE = 'integrity_constraint_violation';
            END;
            $$ LANGUAGE plpgsql
            """,
            "DROP FUNCTION reject_observation_update()"

    execute """
            CREATE TRIGGER observations_reject_update
            BEFORE UPDATE ON observations
            FOR EACH ROW EXECUTE FUNCTION reject_observation_update()
            """,
            "DROP TRIGGER observations_reject_update ON observations"

    create table(:observation_reconciliations, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :organization_id, references(:organizations, on_delete: :delete_all, type: :binary_id),
        null: false

      add :observation_id, references(:observations, on_delete: :delete_all, type: :binary_id),
        null: false

      add :matched_resource_id, references(:resources, on_delete: :nilify_all, type: :binary_id)
      add :status, :string, null: false, default: "pending"
      add :attempt, :integer, null: false
      add :errors, :map, null: false, default: %{}
      add :metadata, :map, null: false, default: %{}
      add :started_at, :"timestamp(3)"
      add :completed_at, :"timestamp(3)"

      timestamps(type: :"timestamp(3)")
    end

    create unique_index(
             :observation_reconciliations,
             [:organization_id, :observation_id, :attempt],
             name: :observation_reconciliations_observation_attempt_index
           )

    create index(:observation_reconciliations, [:organization_id, :status])

    create index(:observation_reconciliations, [:organization_id, :matched_resource_id],
             name: :observation_reconciliations_matched_resource_index
           )

    create table(:resource_identifier_claims, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :organization_id, references(:organizations, on_delete: :delete_all, type: :binary_id),
        null: false

      add :resource_identifier_id,
          references(:resource_identifiers, on_delete: :nilify_all, type: :binary_id)

      add :resource_id, references(:resources, on_delete: :nilify_all, type: :binary_id)
      add :source_id, references(:sources, on_delete: :restrict, type: :binary_id), null: false

      add :observation_id, references(:observations, on_delete: :restrict, type: :binary_id),
        null: false

      add :kind, :string, null: false
      add :value, :string, null: false
      add :normalized_value, :string, null: false
      add :confidence, :integer, null: false, default: 100
      add :first_seen_at, :"timestamp(3)", null: false
      add :last_seen_at, :"timestamp(3)", null: false
      add :metadata, :map, null: false, default: %{}

      timestamps(type: :"timestamp(3)")
    end

    create index(:resource_identifier_claims, [:organization_id, :source_id])
    create index(:resource_identifier_claims, [:organization_id, :observation_id])

    create index(:resource_identifier_claims, [:organization_id, :resource_identifier_id],
             name: :resource_identifier_claims_canonical_index
           )

    create index(:resource_identifier_claims, [:organization_id, :kind, :normalized_value],
             name: :resource_identifier_claims_normalized_value_index
           )

    create unique_index(
             :resource_identifier_claims,
             [:organization_id, :observation_id, :kind, :normalized_value],
             name: :resource_identifier_claims_observation_value_index
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
      add :occurred_at, :"timestamp(3)", null: false

      timestamps(type: :"timestamp(3)")
    end

    create index(:change_events, [:organization_id, :resource_id])
    create index(:change_events, [:organization_id, :source_id])
    create index(:change_events, [:organization_id, :sync_run_id])
    create index(:change_events, [:organization_id, :kind])
    create index(:change_events, [:organization_id, :occurred_at])
  end
end
