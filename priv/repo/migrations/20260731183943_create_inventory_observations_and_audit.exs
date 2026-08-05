defmodule Renga.Repo.Migrations.CreateInventoryObservationsAndAudit do
  use Ecto.Migration

  def change do
    create table(:sync_runs, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :organization_id, references(:organizations, on_delete: :delete_all, type: :binary_id),
        null: false

      add :source_id,
          references(:sources,
            with: [organization_id: :organization_id],
            on_delete: {:nilify, [:source_id]},
            type: :binary_id,
            name: :sync_runs_organization_source_fkey
          )

      add :status, :string, null: false, default: "running"
      add :started_at, :"timestamp(3)", null: false
      add :completed_at, :"timestamp(3)"
      add :resource_count, :integer, null: false, default: 0
      add :error_count, :integer, null: false, default: 0
      add :metadata, :map, null: false, default: %{}

      timestamps(type: :"timestamp(3)")
    end

    create constraint(:sync_runs, :sync_runs_completion_state,
             check: """
             (status = 'running' AND completed_at IS NULL)
             OR
             (status IN ('succeeded', 'failed', 'partial')
              AND completed_at IS NOT NULL
              AND completed_at >= started_at)
             """
           )

    create index(:sync_runs, [:organization_id, :source_id])
    create unique_index(:sync_runs, [:id, :organization_id])
    create unique_index(:sync_runs, [:id, :organization_id, :source_id])
    create index(:sync_runs, [:organization_id, :status])
    create index(:sync_runs, [:organization_id, :started_at])

    create table(:observations, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :organization_id, references(:organizations, on_delete: :delete_all, type: :binary_id),
        null: false

      add :source_id,
          references(:sources,
            with: [organization_id: :organization_id],
            on_delete: :restrict,
            type: :binary_id,
            name: :observations_organization_source_fkey
          ),
          null: false

      add :sync_run_id,
          references(:sync_runs,
            with: [organization_id: :organization_id, source_id: :source_id],
            on_delete: {:nilify, [:sync_run_id]},
            type: :binary_id,
            name: :observations_source_sync_run_fkey
          )

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
    create unique_index(:observations, [:id, :organization_id])
    create unique_index(:observations, [:id, :organization_id, :source_id])

    execute """
            CREATE FUNCTION reject_observation_update() RETURNS trigger AS $$
            BEGIN
              IF NEW.sync_run_id IS NULL
                 AND OLD.sync_run_id IS NOT NULL
                 AND NOT EXISTS (SELECT 1 FROM sync_runs WHERE id = OLD.sync_run_id)
                 AND NEW.id IS NOT DISTINCT FROM OLD.id
                 AND NEW.organization_id IS NOT DISTINCT FROM OLD.organization_id
                 AND NEW.source_id IS NOT DISTINCT FROM OLD.source_id
                 AND NEW.idempotency_key IS NOT DISTINCT FROM OLD.idempotency_key
                 AND NEW.observed_at IS NOT DISTINCT FROM OLD.observed_at
                 AND NEW.payload_digest IS NOT DISTINCT FROM OLD.payload_digest
                 AND NEW.payload IS NOT DISTINCT FROM OLD.payload
                 AND NEW.inserted_at IS NOT DISTINCT FROM OLD.inserted_at THEN
                RETURN NEW;
              END IF;

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

      add :observation_id,
          references(:observations,
            with: [organization_id: :organization_id],
            on_delete: :delete_all,
            type: :binary_id,
            name: :observation_reconciliations_tenant_observation_fkey
          ),
          null: false

      add :matched_resource_id,
          references(:resources,
            with: [organization_id: :organization_id],
            on_delete: {:nilify, [:matched_resource_id]},
            type: :binary_id,
            name: :observation_reconciliations_tenant_resource_fkey
          )

      add :status, :string, null: false, default: "pending"
      add :attempt, :integer, null: false
      add :errors, :map, null: false, default: %{}
      add :metadata, :map, null: false, default: %{}
      add :started_at, :"timestamp(3)"
      add :completed_at, :"timestamp(3)"

      timestamps(type: :"timestamp(3)")
    end

    create constraint(
             :observation_reconciliations,
             :observation_reconciliations_completion_state,
             check: """
             (
               (status IN ('pending', 'running') AND completed_at IS NULL)
               OR
               (status IN ('succeeded', 'failed') AND completed_at IS NOT NULL)
             )
             AND
             (started_at IS NULL OR completed_at IS NULL OR completed_at >= started_at)
             """
           )

    create constraint(:observation_reconciliations, :observation_reconciliations_attempt_positive,
             check: "attempt > 0"
           )

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
          references(:resource_identifiers,
            with: [organization_id: :organization_id],
            on_delete: {:nilify, [:resource_identifier_id]},
            type: :binary_id,
            name: :resource_identifier_claims_tenant_identifier_fkey
          )

      add :resource_id,
          references(:resources,
            with: [organization_id: :organization_id],
            on_delete: {:nilify, [:resource_id]},
            type: :binary_id,
            name: :resource_identifier_claims_tenant_resource_fkey
          )

      add :source_id,
          references(:sources,
            with: [organization_id: :organization_id],
            on_delete: :restrict,
            type: :binary_id,
            name: :resource_identifier_claims_tenant_source_fkey
          ),
          null: false

      add :observation_id,
          references(:observations,
            with: [organization_id: :organization_id, source_id: :source_id],
            on_delete: :restrict,
            type: :binary_id,
            name: :resource_identifier_claims_tenant_observation_fkey
          ),
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

    execute """
            ALTER TABLE resource_identifier_claims
            ADD CONSTRAINT resource_identifier_claims_canonical_resource_fkey
            FOREIGN KEY (resource_identifier_id, organization_id, resource_id)
            REFERENCES resource_identifiers (id, organization_id, resource_id)
            """,
            """
            ALTER TABLE resource_identifier_claims
            DROP CONSTRAINT resource_identifier_claims_canonical_resource_fkey
            """

    create constraint(:resource_identifier_claims, :resource_identifier_claims_confidence_range,
             check: "confidence >= 0 AND confidence <= 100"
           )

    create constraint(:resource_identifier_claims, :resource_identifier_claims_seen_order,
             check: "last_seen_at >= first_seen_at"
           )

    create constraint(
             :resource_identifier_claims,
             :resource_identifier_claims_canonical_requires_resource,
             check: "resource_identifier_id IS NULL OR resource_id IS NOT NULL"
           )

    create table(:change_events, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :organization_id, references(:organizations, on_delete: :delete_all, type: :binary_id),
        null: false

      add :resource_id,
          references(:resources,
            with: [organization_id: :organization_id],
            on_delete: {:nilify, [:resource_id]},
            type: :binary_id,
            name: :change_events_tenant_resource_fkey
          )

      add :source_id,
          references(:sources,
            with: [organization_id: :organization_id],
            on_delete: {:nilify, [:source_id]},
            type: :binary_id,
            name: :change_events_tenant_source_fkey
          )

      add :sync_run_id,
          references(:sync_runs,
            with: [organization_id: :organization_id],
            on_delete: {:nilify, [:sync_run_id]},
            type: :binary_id,
            name: :change_events_tenant_sync_run_fkey
          )

      add :observation_id,
          references(:observations,
            with: [organization_id: :organization_id],
            on_delete: {:nilify, [:observation_id]},
            type: :binary_id,
            name: :change_events_tenant_observation_fkey
          )

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
