defmodule Renga.Repo.Migrations.CreateReconciliationWork do
  use Ecto.Migration

  def up do
    create table(:reconciliation_lanes, primary_key: false) do
      add :organization_id, references(:organizations, type: :binary_id, on_delete: :delete_all),
        primary_key: true

      add :position, :bigint, null: false, default: 0
      add :pending_units, :bigint, null: false, default: 0
      add :pending_bytes, :bigint, null: false, default: 0
      add :last_turn_at, :utc_datetime_usec
      add :token, :binary_id
      add :work_id, :binary_id
      add :version, :bigint, null: false, default: 0
      add :expires_at, :utc_datetime_usec
    end

    create table(:reconciliation_work, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :organization_id, references(:organizations, type: :binary_id, on_delete: :delete_all),
        null: false

      add :observation_id, :binary_id, null: false
      add :source_id, :binary_id, null: false
      add :position, :bigint, null: false
      add :units, :bigint, null: false
      add :bytes, :bigint, null: false
      add :status, :string, null: false, default: "pending"
      add :checkpoint, :bigint, null: false, default: 0
      add :generation, :bigint, null: false, default: 0
      # Historical identity, deliberately not live credential/agent references.
      add :original_key_id, :binary_id, null: false
      add :installation_agent_id, :binary_id, null: false
      add :installation_id, :binary_id, null: false
      add :run_after, :utc_datetime_usec, null: false
      add :quarantine_kind, :string
      add :error, :map, null: false, default: %{}
      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create unique_index(:reconciliation_work, [:id, :organization_id])
    create unique_index(:reconciliation_work, [:organization_id, :position])
    create index(:reconciliation_work, [:organization_id, :observation_id, :position])

    create index(:reconciliation_work, [:organization_id, :position],
             where: "status <> 'succeeded'",
             name: :reconciliation_work_outstanding
           )

    create index(:reconciliation_work, [:observation_id, :organization_id, :source_id])
    create index(:reconciliation_lanes, [:last_turn_at, :organization_id])
    create index(:reconciliation_lanes, [:work_id, :organization_id])

    # NO ACTION, deferred: retain all evidence named by work, while allowing
    # the actual organization cascade to remove both sides in one transaction.
    execute """
    ALTER TABLE reconciliation_work ADD CONSTRAINT reconciliation_work_evidence_fkey
      FOREIGN KEY (observation_id, organization_id, source_id)
      REFERENCES observations (id, organization_id, source_id)
      DEFERRABLE INITIALLY DEFERRED;
    """

    execute """
    ALTER TABLE reconciliation_lanes ADD CONSTRAINT reconciliation_lane_work_fkey
      FOREIGN KEY (work_id, organization_id)
      REFERENCES reconciliation_work (id, organization_id)
      DEFERRABLE INITIALLY DEFERRED;
    """

    create constraint(:reconciliation_lanes, :reconciliation_lane_values,
             check: "position >= 0 AND pending_units >= 0 AND pending_bytes >= 0 AND version >= 0"
           )

    create constraint(:reconciliation_lanes, :reconciliation_lane_lease,
             check:
               "(token IS NULL AND work_id IS NULL AND expires_at IS NULL) OR " <>
                 "(token IS NOT NULL AND work_id IS NOT NULL AND expires_at IS NOT NULL)"
           )

    create constraint(:reconciliation_work, :reconciliation_work_values,
             check:
               "position > 0 AND units > 0 AND bytes >= 0 AND generation >= 0 AND checkpoint >= 0"
           )

    create constraint(:reconciliation_work, :reconciliation_work_status,
             check:
               "(status IN ('pending', 'succeeded') AND quarantine_kind IS NULL) OR " <>
                 "(status = 'quarantined' AND quarantine_kind = 'domain')"
           )

    execute """
    CREATE FUNCTION guard_reconciliation_history() RETURNS trigger AS $$
    BEGIN
      IF TG_OP = 'DELETE' THEN
        IF EXISTS (SELECT 1 FROM organizations WHERE id = OLD.organization_id) THEN
          RAISE EXCEPTION 'retained reconciliation history requires its organization'
            USING ERRCODE = '23514', CONSTRAINT = 'reconciliation_history_retained';
        END IF;
        RETURN OLD;
      END IF;

      IF TG_TABLE_NAME = 'reconciliation_lanes' THEN
        IF NEW.organization_id <> OLD.organization_id OR NEW.position < OLD.position
           OR NEW.version < OLD.version
           OR (OLD.last_turn_at IS NOT NULL AND
               (NEW.last_turn_at IS NULL OR NEW.last_turn_at < OLD.last_turn_at)) THEN
          RAISE EXCEPTION 'lane identity and scheduling history cannot regress'
            USING ERRCODE = '23514', CONSTRAINT = 'reconciliation_lane_history';
        END IF;
      ELSE
        IF (to_jsonb(NEW) - '{status,checkpoint,generation,run_after,quarantine_kind,error}'::text[])
             <> (to_jsonb(OLD) - '{status,checkpoint,generation,run_after,quarantine_kind,error}'::text[])
           OR NEW.generation < OLD.generation OR NEW.checkpoint < OLD.checkpoint
           OR (OLD.status = 'succeeded' AND NEW IS DISTINCT FROM OLD) THEN
          RAISE EXCEPTION 'work identity, provenance and terminal history are immutable'
            USING ERRCODE = '23514', CONSTRAINT = 'reconciliation_work_history';
        END IF;
      END IF;
      RETURN NEW;
    END;
    $$ LANGUAGE plpgsql;
    """

    execute """
    CREATE TRIGGER reconciliation_lanes_history BEFORE UPDATE OR DELETE ON reconciliation_lanes
      FOR EACH ROW EXECUTE FUNCTION guard_reconciliation_history();
    """

    execute """
    CREATE TRIGGER reconciliation_work_history BEFORE UPDATE OR DELETE ON reconciliation_work
      FOR EACH ROW EXECUTE FUNCTION guard_reconciliation_history();
    """
  end

  def down do
    drop table(:reconciliation_lanes)
    drop table(:reconciliation_work)
    execute "DROP FUNCTION guard_reconciliation_history()"
  end
end
