defmodule Renga.Repo.Migrations.StageNeighborGenerations do
  use Ecto.Migration

  @derived ~w(interface_neighbor_matches current_interface_adjacencies topology_findings)
  @storage ["interface_neighbor_evidence" | @derived]
  @inputs ~w(resources hosts interfaces resource_identifiers sources topology_snapshot_events cable_assertions cable_plans cables)

  def up do
    create table(:neighbor_generations, primary_key: false) do
      add :id, :uuid, primary_key: true

      add :organization_id, references(:organizations, type: :uuid, on_delete: :delete_all),
        null: false

      add :watermark, :bigint, null: false
      add :as_of, :utc_datetime_usec, null: false
      add :phase, :text, null: false, default: "matches"
      add :cursor, :uuid
      add :status, :text, null: false, default: "building"
    end

    create unique_index(:neighbor_generations, [:organization_id], where: "status = 'building'")
    create index(:neighbor_generations, [:organization_id, :status])

    create table(:neighbor_generation_heads, primary_key: false) do
      add :organization_id, references(:organizations, type: :uuid, on_delete: :delete_all),
        primary_key: true

      add :version, :bigint, null: false, default: 0
      add :current_generation_id, references(:neighbor_generations, type: :uuid)
    end

    create table(:neighbor_generation_rows, primary_key: false) do
      add :generation_id, references(:neighbor_generations, type: :uuid, on_delete: :delete_all),
        primary_key: true

      add :organization_id, references(:organizations, type: :uuid, on_delete: :delete_all),
        null: false

      add :kind, :text, primary_key: true
      add :key, :text, primary_key: true
      add :payload, :map, null: false
      add :deleted, :boolean, null: false, default: false
      add :processed, :boolean, null: false, default: false
      add :reciprocal, :boolean, null: false, default: false
      add :observed_at, :utc_datetime_usec
      add :observation_id, :uuid
      add :endpoint_a, :uuid
      add :endpoint_b, :uuid
    end

    create index(
             :neighbor_generation_rows,
             [
               :generation_id,
               :kind,
               :processed,
               :reciprocal,
               :observed_at,
               :observation_id,
               :endpoint_a,
               :endpoint_b
             ],
             name: :neighbor_generation_selection
           )

    flush()

    # Push endpoint/evidence predicates below JSON decoding. Without these
    # typed expressions a per-endpoint finding pass scans the whole draft.
    for field <- ~w(id interface_id interface_neighbor_evidence_id interface_a_id interface_b_id) do
      execute(
        "CREATE INDEX neighbor_generation_#{field} ON neighbor_generation_rows (generation_id, kind, ((payload->>'#{field}')::uuid))"
      )
    end

    create index(:neighbor_generation_rows, [:generation_id, :kind, :endpoint_a])
    create index(:neighbor_generation_rows, [:generation_id, :kind, :endpoint_b])

    # Keep the public relation names stable for old writers, raw SQL readers,
    # and archives. Physical constraints and FKs continue to protect storage.
    for table <- @storage do
      execute("ALTER TABLE #{table} RENAME TO #{table}_neighbor_storage")
    end

    execute("""
    CREATE FUNCTION neighbor_read_generation(org uuid) RETURNS uuid LANGUAGE sql STABLE AS $$
      SELECT CASE WHEN current_setting('renga.neighbor_materializing', true) = 'true' THEN NULL
             ELSE COALESCE(NULLIF(current_setting('renga.neighbor_generation', true), '')::uuid,
                           (SELECT current_generation_id FROM neighbor_generation_heads WHERE organization_id = org)) END
    $$
    """)

    for table <- @derived do
      replacement =
        if table == "current_interface_adjacencies", do: "true", else: "r.key = b.id::text"

      execute("""
      DO $$ DECLARE columns text; BEGIN
      SELECT string_agg(CASE
        WHEN a.attname = 'organization_id' THEN 'r.organization_id'
        WHEN a.atttypid = 'uuid'::regtype OR a.attname IN ('status','kind') THEN
          format('(r.payload->>%L)::%s AS %I', a.attname, format_type(a.atttypid,a.atttypmod), a.attname)
        ELSE 'typed.' || quote_ident(a.attname) END, ', ' ORDER BY a.attnum)
      INTO columns FROM pg_attribute a WHERE a.attrelid = '#{table}_neighbor_storage'::regclass AND a.attnum > 0 AND NOT a.attisdropped;
      EXECUTE $view$CREATE VIEW #{table} AS
      SELECT b.* FROM #{table}_neighbor_storage b
      WHERE NOT EXISTS (SELECT 1 FROM neighbor_generations g
        WHERE g.id = neighbor_read_generation(b.organization_id) AND g.organization_id = b.organization_id
          AND (#{if table == "current_interface_adjacencies", do: "true", else: "EXISTS (SELECT 1 FROM neighbor_generation_rows r WHERE r.generation_id = g.id AND r.kind = '#{table}' AND #{replacement})"}))
      UNION ALL
      SELECT $view$ || columns || $view$
      FROM neighbor_generation_rows r JOIN neighbor_generations g ON g.id = r.generation_id
      CROSS JOIN LATERAL jsonb_populate_record(NULL::#{table}_neighbor_storage, r.payload) typed
      WHERE r.kind = '#{table}' AND NOT r.deleted AND g.organization_id = r.organization_id
        AND g.id = neighbor_read_generation(r.organization_id)$view$;
      END $$
      """)
    end

    execute("""
    DO $$ DECLARE columns text; BEGIN
      SELECT string_agg(CASE a.attname
        WHEN 'stale_at' THEN 'CASE WHEN b.stale_at IS NULL AND b.expires_at <= g.as_of THEN b.expires_at ELSE b.stale_at END AS stale_at'
        WHEN 'stale_reason' THEN 'CASE WHEN b.stale_at IS NULL AND b.expires_at <= g.as_of THEN ''expired'' ELSE b.stale_reason END AS stale_reason'
        ELSE 'b.' || quote_ident(a.attname) END, ', ' ORDER BY a.attnum)
      INTO columns FROM pg_attribute a WHERE a.attrelid = 'interface_neighbor_evidence_neighbor_storage'::regclass AND a.attnum > 0 AND NOT a.attisdropped;
      EXECUTE 'CREATE VIEW interface_neighbor_evidence AS SELECT ' || columns ||
        ' FROM interface_neighbor_evidence_neighbor_storage b LEFT JOIN neighbor_generations g ON g.id = neighbor_read_generation(b.organization_id) AND g.organization_id = b.organization_id';
    END $$
    """)

    execute("""
    CREATE FUNCTION materialize_neighbor_generation(org uuid) RETURNS void LANGUAGE plpgsql AS $$
    DECLARE gen uuid; clock timestamptz; relation text; columns text; BEGIN
      IF current_setting('renga.neighbor_materializing', true) = 'true' THEN RETURN; END IF;
      PERFORM 1 FROM organizations WHERE id = org FOR NO KEY UPDATE;
      IF NOT FOUND THEN RETURN; END IF;
      PERFORM pg_advisory_xact_lock(hashtext(org::text), hashtext('cable-state'));
      SELECT h.current_generation_id, g.as_of INTO gen, clock FROM neighbor_generation_heads h
        LEFT JOIN neighbor_generations g ON g.id = h.current_generation_id
        WHERE h.organization_id = org FOR UPDATE OF h;
      IF gen IS NULL THEN RETURN; END IF;
      PERFORM set_config('renga.neighbor_materializing', 'true', true);
      UPDATE interface_neighbor_evidence_neighbor_storage SET stale_at = expires_at, stale_reason = 'expired'
        WHERE organization_id = org AND stale_at IS NULL AND expires_at <= clock;
      DELETE FROM current_interface_adjacencies_neighbor_storage WHERE organization_id = org;
      FOREACH relation IN ARRAY ARRAY['interface_neighbor_matches','current_interface_adjacencies','topology_findings'] LOOP
        SELECT string_agg(quote_ident(a.attname), ', ' ORDER BY a.attnum) INTO columns FROM pg_attribute a
          WHERE a.attrelid = (relation || '_neighbor_storage')::regclass AND a.attnum > 0 AND NOT a.attisdropped;
        EXECUTE 'DELETE FROM ' || relation || '_neighbor_storage b USING neighbor_generation_rows r WHERE r.generation_id = $1 AND r.kind = $2 AND r.deleted AND b.id::text = r.key' USING gen, relation;
        EXECUTE 'INSERT INTO ' || relation || '_neighbor_storage SELECT (jsonb_populate_record(NULL::' || relation || '_neighbor_storage, r.payload)).* FROM neighbor_generation_rows r WHERE r.generation_id = $1 AND r.kind = $2 AND NOT r.deleted ON CONFLICT (id) DO UPDATE SET (' || columns || ') = (SELECT ' || columns || ' FROM jsonb_populate_record(NULL::' || relation || '_neighbor_storage, to_jsonb(EXCLUDED)))' USING gen, relation;
      END LOOP;
      UPDATE neighbor_generation_heads SET current_generation_id = NULL WHERE organization_id = org;
      UPDATE neighbor_generations SET status = 'obsolete' WHERE id = gen;
      PERFORM set_config('renga.neighbor_materializing', 'false', true);
    END $$
    """)

    execute("""
    CREATE FUNCTION neighbor_input_changed() RETURNS trigger LANGUAGE plpgsql AS $$
    DECLARE org uuid; fields text[]; before_value jsonb; after_value jsonb; BEGIN
      IF current_setting('renga.neighbor_materializing', true) = 'true' THEN RETURN COALESCE(NEW, OLD); END IF;
      -- An unused source cannot affect topology; its first evidence will
      -- invalidate the version. Do not serialize first check-ins with builds.
      IF TG_OP = 'INSERT' AND TG_TABLE_NAME = 'sources' THEN RETURN NEW; END IF;
      IF TG_OP = 'UPDATE' AND (to_jsonb(NEW) - 'updated_at' - 'inserted_at') IS NOT DISTINCT FROM (to_jsonb(OLD) - 'updated_at' - 'inserted_at') THEN RETURN NEW; END IF;
      -- Inventory presence timestamps are not topology input. Counting them
      -- would invalidate a large expiry run on every unrelated host check-in.
      fields := CASE TG_TABLE_NAME
        WHEN 'resources' THEN ARRAY['id','organization_id','kind','name','display_name']
        WHEN 'hosts' THEN ARRAY['id','organization_id','resource_id','hostname','fqdn']
        WHEN 'interfaces' THEN ARRAY['id','organization_id','resource_id','name','mac_address','kind','status']
        WHEN 'resource_identifiers' THEN ARRAY['id','organization_id','resource_id','kind','value','normalized_value']
        ELSE NULL END;
      IF TG_OP = 'UPDATE' AND fields IS NOT NULL THEN
        SELECT jsonb_object_agg(key,value) INTO before_value FROM jsonb_each(to_jsonb(OLD)) WHERE key = ANY(fields);
        SELECT jsonb_object_agg(key,value) INTO after_value FROM jsonb_each(to_jsonb(NEW)) WHERE key = ANY(fields);
        IF before_value IS NOT DISTINCT FROM after_value THEN RETURN NEW; END IF;
      END IF;
      IF TG_OP = 'UPDATE' AND TG_TABLE_NAME = 'sources' THEN
        IF jsonb_build_array(NEW.id,NEW.organization_id,NEW.kind,NEW.status,NEW.metadata->'interface_neighbor_snapshot_policy') IS NOT DISTINCT FROM
          jsonb_build_array(OLD.id,OLD.organization_id,OLD.kind,OLD.status,OLD.metadata->'interface_neighbor_snapshot_policy') THEN RETURN NEW; END IF;
      END IF;
      org := COALESCE(NEW.organization_id, OLD.organization_id);
      PERFORM materialize_neighbor_generation(org);
      IF EXISTS (SELECT 1 FROM organizations WHERE id = org) THEN
        INSERT INTO neighbor_generation_heads(organization_id, version) VALUES(org, 1)
        ON CONFLICT (organization_id) DO UPDATE SET version = neighbor_generation_heads.version + 1;
      END IF;
      RETURN COALESCE(NEW, OLD);
    END $$
    """)

    execute("""
    CREATE FUNCTION write_neighbor_view() RETURNS trigger LANGUAGE plpgsql AS $$
    DECLARE relation text := TG_TABLE_NAME || '_neighbor_storage'; columns text; BEGIN
      PERFORM materialize_neighbor_generation(COALESCE(NEW.organization_id, OLD.organization_id));
      IF TG_OP = 'DELETE' THEN EXECUTE 'DELETE FROM ' || relation || ' WHERE id = $1' USING OLD.id; RETURN OLD; END IF;
      IF TG_OP = 'INSERT' THEN
        EXECUTE 'INSERT INTO ' || relation || ' SELECT (jsonb_populate_record(NULL::' || relation || ', $1)).*' USING to_jsonb(NEW);
      ELSE
        SELECT string_agg(quote_ident(a.attname), ', ' ORDER BY a.attnum) INTO columns FROM pg_attribute a
          WHERE a.attrelid = relation::regclass AND a.attnum > 0 AND NOT a.attisdropped;
        EXECUTE 'UPDATE ' || relation || ' SET (' || columns || ') = (SELECT ' || columns || ' FROM jsonb_populate_record(NULL::' || relation || ', $1)) WHERE id = $2' USING to_jsonb(NEW), OLD.id;
      END IF;
      RETURN NEW;
    END $$
    """)

    for table <- @storage do
      execute("""
      DO $$ DECLARE item record; BEGIN
        FOR item IN SELECT a.attname, pg_get_expr(d.adbin,d.adrelid) AS expression
          FROM pg_attrdef d JOIN pg_attribute a ON a.attrelid = d.adrelid AND a.attnum = d.adnum
          WHERE d.adrelid = '#{table}_neighbor_storage'::regclass LOOP
          EXECUTE 'ALTER VIEW #{table} ALTER COLUMN ' || quote_ident(item.attname) || ' SET DEFAULT ' || item.expression;
        END LOOP;
      END $$
      """)

      execute(
        "CREATE TRIGGER write_neighbor_view INSTEAD OF INSERT OR UPDATE OR DELETE ON #{table} FOR EACH ROW EXECUTE FUNCTION write_neighbor_view()"
      )
    end

    for table <- @inputs ++ Enum.map(@storage, &(&1 <> "_neighbor_storage")) do
      execute(
        "CREATE TRIGGER neighbor_input_changed BEFORE INSERT OR UPDATE OR DELETE ON #{table} FOR EACH ROW EXECUTE FUNCTION neighbor_input_changed()"
      )
    end
  end

  def down do
    execute(
      "SELECT materialize_neighbor_generation(organization_id) FROM neighbor_generation_heads WHERE current_generation_id IS NOT NULL"
    )

    for table <- @inputs ++ Enum.map(@storage, &(&1 <> "_neighbor_storage")),
        do: execute("DROP TRIGGER neighbor_input_changed ON #{table}")

    for table <- @storage do
      execute("DROP VIEW #{table}")
      execute("ALTER TABLE #{table}_neighbor_storage RENAME TO #{table}")
    end

    execute("DROP FUNCTION write_neighbor_view()")
    execute("DROP FUNCTION neighbor_input_changed()")
    execute("DROP FUNCTION materialize_neighbor_generation(uuid)")
    execute("DROP FUNCTION neighbor_read_generation(uuid)")
    drop table(:neighbor_generation_rows)
    drop table(:neighbor_generation_heads)
    drop table(:neighbor_generations)
  end
end
