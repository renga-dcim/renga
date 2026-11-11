defmodule Renga.Repo.Migrations.CreateJobEvidenceReservations do
  use Ecto.Migration

  def change do
    create table(:job_evidence_reservations, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :organization_id, references(:organizations, type: :binary_id, on_delete: :delete_all),
        null: false

      # Historical attempt authority survives lease expiry and job retention.
      add :job_id, :binary_id, null: false
      add :agent_id, :binary_id, null: false
      add :installation_id, :binary_id, null: false
      add :attempt, :integer, null: false
      add :token_hash, :binary, null: false
      add :remaining_items, :bigint, null: false
      add :remaining_bytes, :bigint, null: false
    end

    create unique_index(:job_evidence_reservations, [:job_id, :attempt])
    create unique_index(:job_evidence_reservations, [:id, :organization_id])

    create index(:job_evidence_reservations, [:organization_id],
             where: "remaining_items > 0 OR remaining_bytes > 0"
           )

    create constraint(:job_evidence_reservations, :job_evidence_reservation_values,
             check: "attempt > 0 AND remaining_items >= 0 AND remaining_bytes >= 0"
           )

    alter table(:reconciliation_work) do
      add :job_reservation_id, :binary_id
      add :job_body_digest, :string
    end

    execute """
            ALTER TABLE reconciliation_work ADD CONSTRAINT reconciliation_work_job_reservation_fkey
              FOREIGN KEY (job_reservation_id, organization_id)
              REFERENCES job_evidence_reservations (id, organization_id)
              DEFERRABLE INITIALLY DEFERRED
            """,
            "ALTER TABLE reconciliation_work DROP CONSTRAINT reconciliation_work_job_reservation_fkey"

    create constraint(:reconciliation_work, :reconciliation_work_job_evidence,
             check: "(job_reservation_id IS NULL) = (job_body_digest IS NULL)"
           )

    create index(:reconciliation_work, [:job_reservation_id])

    create index(:reconciliation_work, [:organization_id],
             name: :protected_evidence_pending_usage,
             where: "job_reservation_id IS NOT NULL AND status <> 'succeeded'"
           )

    execute """
            CREATE FUNCTION guard_job_evidence_reservation() RETURNS trigger AS $$
            BEGIN
              IF TG_OP = 'DELETE' THEN
                IF EXISTS (SELECT 1 FROM organizations WHERE id = OLD.organization_id) THEN
                  RAISE EXCEPTION 'attempt authority is retained with its organization';
                END IF;
                RETURN OLD;
              END IF;
              IF (to_jsonb(NEW) - '{remaining_items,remaining_bytes}'::text[]) <>
                 (to_jsonb(OLD) - '{remaining_items,remaining_bytes}'::text[])
                 OR NEW.remaining_items > OLD.remaining_items OR NEW.remaining_bytes > OLD.remaining_bytes THEN
                RAISE EXCEPTION 'attempt authority is immutable and allowance cannot grow';
              END IF;
              RETURN NEW;
            END;
            $$ LANGUAGE plpgsql
            """,
            "DROP FUNCTION guard_job_evidence_reservation()"

    execute """
            CREATE TRIGGER job_evidence_reservation_history BEFORE UPDATE OR DELETE ON job_evidence_reservations
              FOR EACH ROW EXECUTE FUNCTION guard_job_evidence_reservation()
            """,
            "DROP TRIGGER job_evidence_reservation_history ON job_evidence_reservations"

    # Older code cannot account for protected work. Refuse a downgrade rather
    # than silently moving accepted work into an already-full ordinary backlog.
    execute "SELECT 1", """
    DO $$ BEGIN
      IF EXISTS (SELECT 1 FROM job_evidence_reservations WHERE remaining_items > 0 OR remaining_bytes > 0)
        OR EXISTS (SELECT 1 FROM reconciliation_work WHERE job_reservation_id IS NOT NULL AND status <> 'succeeded') THEN
        RAISE EXCEPTION 'drain protected evidence and finish leased attempts before downgrading';
      END IF;
    END $$
    """
  end
end
