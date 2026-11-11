defmodule Renga.Repo.Migrations.PreventNeighborInputLockInversion do
  use Ecto.Migration

  # A row trigger runs after the input tuple is locked. Legacy/direct writers
  # must fail retryably rather than wait for a canonical writer that may need
  # that tuple. Current writers take the organization fence first.
  def up, do: execute(materializer("NOWAIT"))
  def down, do: execute(materializer(""))

  defp materializer(wait) do
    """
    CREATE OR REPLACE FUNCTION materialize_neighbor_generation(org uuid) RETURNS void LANGUAGE plpgsql AS $$
    DECLARE gen uuid; clock timestamptz; relation text; columns text; BEGIN
      IF current_setting('renga.neighbor_materializing', true) = 'true' THEN RETURN; END IF;
      PERFORM 1 FROM organizations WHERE id = org FOR NO KEY UPDATE #{wait};
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
    """
  end
end
