defmodule Renga.Repo.Migrations.CreateReconciliationQuotaRetries do
  use Ecto.Migration

  def up do
    drop constraint(:reconciliation_work, :reconciliation_work_status)

    create constraint(:reconciliation_work, :reconciliation_work_status,
             check:
               "(status IN ('pending', 'succeeded', 'quota_deferred') AND quarantine_kind IS NULL) OR " <>
                 "(status = 'quarantined' AND quarantine_kind = 'domain')"
           )

    create unique_index(:reconciliation_work, [:id, :observation_id])

    # The existing work retains the only pending-work reservation. This row is
    # a retry obligation, not another admission or another resource reservation.
    create table(:reconciliation_quota_retries, primary_key: false) do
      add :work_id, :binary_id, primary_key: true
      add :observation_id, :binary_id, null: false
      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create unique_index(:reconciliation_quota_retries, [:observation_id])

    execute """
    ALTER TABLE reconciliation_quota_retries ADD CONSTRAINT reconciliation_quota_retry_work_fkey
      FOREIGN KEY (work_id, observation_id) REFERENCES reconciliation_work (id, observation_id)
      ON DELETE CASCADE;
    """

    execute quota_finding_function(true)

    execute """
    CREATE FUNCTION renga_refresh_retry_quota_finding() RETURNS trigger LANGUAGE plpgsql AS $$
    DECLARE org uuid;
    BEGIN
      SELECT organization_id INTO org FROM reconciliation_work
        WHERE id = CASE WHEN TG_OP = 'DELETE' THEN OLD.work_id ELSE NEW.work_id END;
      -- The organization and work can already be gone during tenant cascade.
      IF org IS NOT NULL AND EXISTS (SELECT 1 FROM organizations WHERE id = org) THEN
        -- A rejected first report rolls back its usage row too. Establish zero
        -- accounting before refresh; rejected envelopes are never charged.
        INSERT INTO organization_quota_usage(organization_id, name) VALUES (org, 'resources')
          ON CONFLICT DO NOTHING;
        PERFORM renga_refresh_quota_finding(org, 'resources');
      END IF;
      RETURN NULL;
    END $$;
    """

    execute """
    CREATE TRIGGER reconciliation_quota_retry_finding AFTER INSERT OR DELETE
      ON reconciliation_quota_retries FOR EACH ROW
      EXECUTE FUNCTION renga_refresh_retry_quota_finding();
    """
  end

  def down do
    drop table(:reconciliation_quota_retries)
    execute "DROP FUNCTION renga_refresh_retry_quota_finding()"
    execute quota_finding_function(false)

    # DROP TABLE does not fire retry DELETE triggers. Re-evaluate the restored
    # threshold so retry-only findings resolve without closing capacity findings.
    execute """
    SELECT renga_refresh_quota_finding(organization_id, name)
      FROM organization_quota_usage WHERE name = 'resources'
    """

    drop index(:reconciliation_work, [:id, :observation_id])

    execute "UPDATE reconciliation_work SET status = 'pending' WHERE status = 'quota_deferred'"
    drop constraint(:reconciliation_work, :reconciliation_work_status)

    create constraint(:reconciliation_work, :reconciliation_work_status,
             check:
               "(status IN ('pending', 'succeeded') AND quarantine_kind IS NULL) OR " <>
                 "(status = 'quarantined' AND quarantine_kind = 'domain')"
           )
  end

  defp quota_finding_function(deferred?) do
    deferred =
      if deferred?,
        do: """
        OR (quota = 'resources' AND EXISTS (
          SELECT 1 FROM reconciliation_quota_retries retry
          JOIN reconciliation_work work ON work.id = retry.work_id
          WHERE work.organization_id = org))
        """,
        else: ""

    """
    CREATE OR REPLACE FUNCTION renga_refresh_quota_finding(org uuid, quota text) RETURNS void
    LANGUAGE plpgsql AS $$
    DECLARE held bigint; cap bigint;
    BEGIN
      SELECT used + reserved INTO held FROM organization_quota_usage
        WHERE organization_id = org AND name = quota FOR UPDATE;
      IF NOT FOUND THEN RETURN; END IF;
      SELECT COALESCE((SELECT value FROM organization_limits WHERE organization_id = org AND name = quota), value)
        INTO cap FROM organization_quota_defaults WHERE name = quota;
      IF held::numeric * 5 >= cap::numeric * 4 #{deferred} THEN
        INSERT INTO organization_quota_findings (organization_id, name, used, capacity, opened_at)
        VALUES (org, quota, held, cap, timezone('UTC', clock_timestamp()))
        ON CONFLICT (organization_id, name) DO UPDATE SET
          used = EXCLUDED.used, capacity = EXCLUDED.capacity,
          id = CASE WHEN organization_quota_findings.resolved_at IS NULL
            THEN organization_quota_findings.id ELSE gen_random_uuid() END,
          opened_at = CASE WHEN organization_quota_findings.resolved_at IS NULL
            THEN organization_quota_findings.opened_at ELSE EXCLUDED.opened_at END,
          last_observed_at = EXCLUDED.last_observed_at,
          resolved_at = NULL;
      ELSE
        UPDATE organization_quota_findings SET used = held, capacity = cap,
          last_observed_at = timezone('UTC', clock_timestamp()),
          resolved_at = COALESCE(resolved_at, timezone('UTC', clock_timestamp()))
          WHERE organization_id = org AND name = quota;
      END IF;
    END $$;
    """
  end
end
