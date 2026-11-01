defmodule Renga.Repo.Migrations.AllowDeletedIntakeKeyNullification do
  use Ecto.Migration

  # Keep the existing sync-run exception unchanged. The intake-key FK already
  # promises SET NULL, but its later addition did not update the immutable-row
  # trigger. Allow only that parent-deletion action, never evidence rewriting.
  @sync_run_exception """
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
  """

  def up do
    execute """
    CREATE OR REPLACE FUNCTION reject_observation_update() RETURNS trigger AS $$
    BEGIN
      IF NEW.intake_api_key_id IS DISTINCT FROM OLD.intake_api_key_id THEN
        IF NEW.intake_api_key_id IS NULL AND OLD.intake_api_key_id IS NOT NULL
           AND NOT EXISTS (SELECT 1 FROM intake_api_keys
             WHERE id = OLD.intake_api_key_id AND organization_id = OLD.organization_id)
           AND (to_jsonb(NEW) - 'intake_api_key_id') = (to_jsonb(OLD) - 'intake_api_key_id') THEN
          RETURN NEW;
        END IF;
        RAISE EXCEPTION 'observations are immutable'
          USING ERRCODE = 'integrity_constraint_violation';
      END IF;
      #{@sync_run_exception}
      RAISE EXCEPTION 'observations are immutable'
        USING ERRCODE = 'integrity_constraint_violation';
    END;
    $$ LANGUAGE plpgsql
    """
  end

  def down do
    execute """
    CREATE OR REPLACE FUNCTION reject_observation_update() RETURNS trigger AS $$
    BEGIN
      #{@sync_run_exception}
      RAISE EXCEPTION 'observations are immutable'
        USING ERRCODE = 'integrity_constraint_violation';
    END;
    $$ LANGUAGE plpgsql
    """
  end
end
