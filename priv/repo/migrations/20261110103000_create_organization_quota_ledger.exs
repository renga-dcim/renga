defmodule Renga.Repo.Migrations.CreateOrganizationQuotaLedger do
  use Ecto.Migration

  def up do
    execute """
    CREATE TABLE organization_quota_defaults (
      name text PRIMARY KEY, value bigint NOT NULL CHECK (value >= 0)
    );
    """

    execute """
    INSERT INTO organization_quota_defaults VALUES
      ('resources', 1000000), ('agents', 100000),
      ('installation_identities', 100000), ('intake_keys', 10000),
      ('export_archive_bytes', 10737418240);
    """

    execute """
    CREATE TABLE organization_quota_usage (
      organization_id uuid NOT NULL REFERENCES organizations(id) ON DELETE CASCADE,
      name text NOT NULL REFERENCES organization_quota_defaults(name),
      used bigint NOT NULL DEFAULT 0 CHECK (used >= 0),
      reserved bigint NOT NULL DEFAULT 0 CHECK (reserved >= 0),
      PRIMARY KEY (organization_id, name)
    );
    """

    execute """
    CREATE TABLE organization_quota_findings (
      id uuid NOT NULL DEFAULT gen_random_uuid() UNIQUE,
      organization_id uuid NOT NULL REFERENCES organizations(id) ON DELETE CASCADE,
      name text NOT NULL,
      used bigint NOT NULL, capacity bigint NOT NULL,
      opened_at timestamp(6) NOT NULL,
      last_observed_at timestamp(6) NOT NULL DEFAULT timezone('UTC', clock_timestamp()),
      resolved_at timestamp(6),
      PRIMARY KEY (organization_id, name)
    );
    """

    execute """
    ALTER TABLE finding_workflows
      ALTER COLUMN resource_id DROP NOT NULL,
      DROP CONSTRAINT finding_workflows_valid_domain,
      ADD CONSTRAINT finding_workflows_valid_domain CHECK
        (domain IN ('component','hardware_match','placement','topology','address','collector','power','quota')),
      ADD CONSTRAINT finding_workflows_subject CHECK ((domain = 'quota') = (resource_id IS NULL)),
      ADD CONSTRAINT finding_workflows_organization_fkey FOREIGN KEY (organization_id)
        REFERENCES organizations(id) ON DELETE CASCADE;
    """

    execute """
    CREATE FUNCTION renga_refresh_quota_finding(org uuid, quota text) RETURNS void
    LANGUAGE plpgsql AS $$
    DECLARE held bigint; cap bigint;
    BEGIN
      SELECT used + reserved INTO held FROM organization_quota_usage
        WHERE organization_id = org AND name = quota FOR UPDATE;
      IF NOT FOUND THEN RETURN; END IF;
      SELECT COALESCE((SELECT value FROM organization_limits WHERE organization_id = org AND name = quota), value)
        INTO cap FROM organization_quota_defaults WHERE name = quota;
      IF held::numeric * 5 >= cap::numeric * 4 THEN
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

    execute """
    CREATE FUNCTION renga_charge_quota(org uuid, quota text, used_delta bigint, reserved_delta bigint)
    RETURNS void LANGUAGE plpgsql AS $$
    DECLARE current_used bigint; current_reserved bigint; capacity bigint;
    BEGIN
      -- During a tenant cascade the parent's ledger is being deleted too.
      IF NOT EXISTS (SELECT 1 FROM organizations WHERE id = org) THEN RETURN; END IF;
      INSERT INTO organization_quota_usage(organization_id, name) VALUES (org, quota)
        ON CONFLICT DO NOTHING;
      SELECT used, reserved INTO current_used, current_reserved FROM organization_quota_usage
        WHERE organization_id = org AND name = quota FOR UPDATE;
      SELECT COALESCE((SELECT value FROM organization_limits WHERE organization_id = org AND name = quota), value)
        INTO capacity FROM organization_quota_defaults WHERE name = quota;
      IF used_delta::numeric + reserved_delta > 0 AND
         current_used::numeric + current_reserved + used_delta + reserved_delta > capacity THEN
        RAISE EXCEPTION '% quota exceeded', quota USING
          ERRCODE = '23514', CONSTRAINT = 'renga_quota_' || quota || '_exceeded';
      END IF;
      UPDATE organization_quota_usage SET used = used + used_delta, reserved = reserved + reserved_delta
        WHERE organization_id = org AND name = quota;
      PERFORM renga_refresh_quota_finding(org, quota);
    END $$;
    """

    execute """
    CREATE FUNCTION renga_count_quota() RETURNS trigger LANGUAGE plpgsql AS $$
    DECLARE before_count bigint := 0; after_count bigint := 0; org uuid;
    BEGIN
      IF TG_OP <> 'INSERT' THEN
        org := OLD.organization_id;
        before_count := CASE
          WHEN TG_ARGV[0] = 'installation_identities' THEN (to_jsonb(OLD)->>'installation_id' IS NOT NULL)::int
          WHEN TG_ARGV[0] = 'intake_keys' THEN (to_jsonb(OLD)->>'status' = 'active')::int ELSE 1 END;
      END IF;
      IF TG_OP <> 'DELETE' THEN
        IF org IS NOT NULL AND org <> NEW.organization_id THEN
          RAISE EXCEPTION 'quota owners cannot move between organizations';
        END IF;
        org := NEW.organization_id;
        after_count := CASE
          WHEN TG_ARGV[0] = 'installation_identities' THEN (to_jsonb(NEW)->>'installation_id' IS NOT NULL)::int
          WHEN TG_ARGV[0] = 'intake_keys' THEN (to_jsonb(NEW)->>'status' = 'active')::int ELSE 1 END;
      END IF;
      IF before_count <> after_count THEN
        PERFORM renga_charge_quota(org, TG_ARGV[0], after_count - before_count, 0::bigint);
      END IF;
      RETURN NULL;
    END $$;
    """

    for {table, name, condition} <- [
          {"resources", "resources", "true"},
          {"agents", "agents", "true"},
          {"agents", "installation_identities", "installation_id IS NOT NULL"},
          {"intake_api_keys", "intake_keys", "status = 'active'"}
        ] do
      # Seed existing usage without refusing a deployment already over quota.
      execute """
      INSERT INTO organization_quota_usage(organization_id, name, used)
        SELECT organization_id, '#{name}', count(*) FROM #{table} WHERE #{condition} GROUP BY organization_id;
      """

      execute """
      CREATE TRIGGER #{table}_quota_#{name} AFTER INSERT OR UPDATE OR DELETE ON #{table}
        FOR EACH ROW EXECUTE FUNCTION renga_count_quota('#{name}');
      """
    end

    execute "ALTER TABLE organization_exports ADD COLUMN retained_bytes bigint NOT NULL DEFAULT 0 CHECK (retained_bytes >= 0)"

    execute """
    UPDATE organization_exports SET retained_bytes = COALESCE((SELECT sum(octet_length(data))
      FROM organization_export_chunks WHERE export_id = organization_exports.id), 0);
    """

    execute "UPDATE organization_exports SET maximum_bytes = GREATEST(maximum_bytes, retained_bytes)"

    execute """
    INSERT INTO organization_quota_usage(organization_id, name, used, reserved)
      SELECT organization_id, 'export_archive_bytes', sum(retained_bytes),
        sum(CASE WHEN status = 'running' THEN maximum_bytes - retained_bytes ELSE 0 END)
      FROM organization_exports GROUP BY organization_id;
    """

    execute """
    CREATE FUNCTION renga_export_quota() RETURNS trigger LANGUAGE plpgsql AS $$
    DECLARE old_used bigint := 0; old_reserved bigint := 0;
      new_used bigint := 0; new_reserved bigint := 0; org uuid;
    BEGIN
      IF TG_OP <> 'INSERT' THEN
        org := OLD.organization_id;
        old_used := OLD.retained_bytes;
        IF OLD.status = 'running' THEN old_reserved := OLD.maximum_bytes - old_used; END IF;
      END IF;
      IF TG_OP <> 'DELETE' THEN
        org := NEW.organization_id;
        new_used := NEW.retained_bytes;
        IF new_used > NEW.maximum_bytes THEN
          RAISE EXCEPTION 'export exceeds its reserved maximum bytes' USING ERRCODE = '23514';
        END IF;
        IF NEW.status = 'running' THEN new_reserved := NEW.maximum_bytes - new_used; END IF;
      END IF;
      PERFORM renga_charge_quota(org, 'export_archive_bytes', new_used - old_used, new_reserved - old_reserved);
      RETURN NULL;
    END $$;
    """

    execute """
    CREATE TRIGGER organization_exports_quota AFTER INSERT OR UPDATE OR DELETE ON organization_exports
      FOR EACH ROW EXECUTE FUNCTION renga_export_quota();
    """

    execute """
    CREATE FUNCTION renga_export_chunk_quota() RETURNS trigger LANGUAGE plpgsql AS $$
    BEGIN
      IF TG_OP = 'INSERT' THEN
        UPDATE organization_exports SET retained_bytes = retained_bytes + octet_length(NEW.data)
          WHERE id = NEW.export_id;
      ELSE
        UPDATE organization_exports SET retained_bytes = retained_bytes - octet_length(OLD.data)
          WHERE id = OLD.export_id;
      END IF;
      RETURN NULL;
    END $$;
    """

    execute """
    CREATE TRIGGER organization_export_chunks_quota AFTER INSERT OR DELETE ON organization_export_chunks
      FOR EACH ROW EXECUTE FUNCTION renga_export_chunk_quota();
    """

    execute """
    CREATE FUNCTION renga_quota_policy_changed() RETURNS trigger LANGUAGE plpgsql AS $$
    DECLARE org uuid; quota text;
    BEGIN
      IF TG_TABLE_NAME = 'organization_limits' THEN
        IF TG_OP = 'DELETE' THEN org := OLD.organization_id; quota := OLD.name;
        ELSE org := NEW.organization_id; quota := NEW.name; END IF;
        IF EXISTS (SELECT 1 FROM organization_quota_defaults WHERE name = quota) THEN
          INSERT INTO organization_quota_usage(organization_id, name) SELECT org, quota
            WHERE EXISTS (SELECT 1 FROM organizations WHERE id = org) ON CONFLICT DO NOTHING;
          PERFORM renga_refresh_quota_finding(org, quota);
        END IF;
      ELSE
        FOR org IN SELECT organization_id FROM organization_quota_usage WHERE name = NEW.name ORDER BY organization_id LOOP
          PERFORM id FROM organizations WHERE id = org FOR KEY SHARE;
          PERFORM renga_refresh_quota_finding(org, NEW.name);
        END LOOP;
      END IF;
      RETURN NULL;
    END $$;
    """

    execute """
    CREATE TRIGGER organization_limits_quota AFTER INSERT OR UPDATE OR DELETE ON organization_limits
      FOR EACH ROW EXECUTE FUNCTION renga_quota_policy_changed();
    """

    execute """
    CREATE TRIGGER organization_quota_defaults_changed AFTER UPDATE ON organization_quota_defaults
      FOR EACH ROW EXECUTE FUNCTION renga_quota_policy_changed();
    """

    execute "SELECT renga_refresh_quota_finding(organization_id, name) FROM organization_quota_usage"
  end

  def down do
    execute "DELETE FROM finding_workflows WHERE domain = 'quota'"

    execute """
    ALTER TABLE finding_workflows
      DROP CONSTRAINT finding_workflows_subject,
      DROP CONSTRAINT finding_workflows_organization_fkey,
      DROP CONSTRAINT finding_workflows_valid_domain,
      ADD CONSTRAINT finding_workflows_valid_domain CHECK
        (domain IN ('component','hardware_match','placement','topology','address','collector','power')),
      ALTER COLUMN resource_id SET NOT NULL;
    """

    execute "DROP TRIGGER organization_limits_quota ON organization_limits"
    execute "DROP TRIGGER organization_export_chunks_quota ON organization_export_chunks"
    execute "DROP TRIGGER organization_exports_quota ON organization_exports"
    execute "ALTER TABLE organization_exports DROP COLUMN retained_bytes"

    for {table, name} <- [
          {"resources", "resources"},
          {"agents", "agents"},
          {"agents", "installation_identities"},
          {"intake_api_keys", "intake_keys"}
        ],
        do: execute("DROP TRIGGER #{table}_quota_#{name} ON #{table}")

    execute "DROP TABLE organization_quota_findings, organization_quota_usage, organization_quota_defaults CASCADE"

    execute "DROP FUNCTION renga_quota_policy_changed(), renga_export_chunk_quota(), renga_export_quota(), renga_count_quota(), renga_charge_quota(uuid,text,bigint,bigint), renga_refresh_quota_finding(uuid,text)"
  end
end
