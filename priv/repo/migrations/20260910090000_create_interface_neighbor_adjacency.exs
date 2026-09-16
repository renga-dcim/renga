defmodule Renga.Repo.Migrations.CreateInterfaceNeighborAdjacency do
  use Ecto.Migration

  def change do
    execute(
      """
      ALTER TABLE topology_snapshot_events
      DROP CONSTRAINT topology_snapshot_events_valid_section,
      ADD CONSTRAINT topology_snapshot_events_valid_section
      CHECK (section IN ('interface_vlans', 'interface_neighbors', 'interface_relationships'))
      """,
      """
      DO $$
      BEGIN
        DELETE FROM topology_findings
        WHERE kind IN (
          'ambiguous_remote_identity',
          'asymmetric_neighbor',
          'conflicting_neighbors',
          'expired_adjacency'
        );

        DELETE FROM topology_snapshot_events
        WHERE section = 'interface_neighbors';

        ALTER TABLE topology_snapshot_events
        DROP CONSTRAINT topology_snapshot_events_valid_section,
        ADD CONSTRAINT topology_snapshot_events_valid_section
        CHECK (section IN ('interface_vlans', 'interface_relationships'));
      END
      $$
      """
    )

    create table(:interface_neighbor_evidence, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :organization_id, references(:organizations, on_delete: :delete_all, type: :binary_id),
        null: false

      add :local_interface_id,
          references(:interfaces,
            with: [organization_id: :organization_id],
            on_delete: :delete_all,
            type: :binary_id,
            name: :interface_neighbor_evidence_tenant_interface_fkey
          ),
          null: false

      add :source_id,
          references(:sources,
            with: [organization_id: :organization_id],
            on_delete: :restrict,
            type: :binary_id,
            name: :interface_neighbor_evidence_tenant_source_fkey
          ),
          null: false

      add :observation_id,
          references(:observations,
            with: [organization_id: :organization_id, source_id: :source_id],
            on_delete: :restrict,
            type: :binary_id,
            name: :interface_neighbor_evidence_tenant_observation_fkey
          ),
          null: false

      add :protocol, :string, null: false
      add :remote_chassis_id, :string, null: false
      add :remote_chassis_id_kind, :string
      add :remote_chassis_id_normalized, :string, null: false
      add :remote_system_name, :string
      add :remote_port_id, :string, null: false
      add :remote_port_id_kind, :string
      add :remote_port_id_normalized, :string, null: false
      add :remote_port_description, :string
      add :ttl_seconds, :integer, null: false
      add :observed_at, :"timestamp(3)", null: false
      add :expires_at, :"timestamp(3)", null: false
      add :stale_at, :"timestamp(3)"
      add :stale_reason, :string
      add :metadata, :map, null: false, default: %{}
      timestamps(type: :"timestamp(3)", updated_at: false)
    end

    create unique_index(
             :interface_neighbor_evidence,
             [
               :organization_id,
               :observation_id,
               :local_interface_id,
               :protocol,
               :remote_chassis_id_kind,
               :remote_chassis_id_normalized,
               :remote_port_id_kind,
               :remote_port_id_normalized
             ],
             name: :interface_neighbor_evidence_observation_endpoint_index,
             nulls_distinct: false
           )

    create index(
             :interface_neighbor_evidence,
             [
               :organization_id,
               :local_interface_id,
               :source_id,
               :protocol,
               :remote_chassis_id_kind,
               :remote_chassis_id_normalized,
               :remote_port_id_kind,
               :remote_port_id_normalized,
               desc: :observed_at,
               desc: :observation_id
             ],
             name: :interface_neighbor_evidence_identity_order_index
           )

    create index(:interface_neighbor_evidence, [:expires_at, :organization_id],
             where: "stale_at IS NULL",
             name: :interface_neighbor_evidence_active_expiry_index
           )

    create unique_index(:interface_neighbor_evidence, [:id, :organization_id])

    create index(
             :interface_neighbor_evidence,
             [:organization_id, :local_interface_id, :source_id, :observed_at],
             where: "stale_at IS NULL",
             name: :interface_neighbor_evidence_active_local_source_index
           )

    create constraint(:interface_neighbor_evidence, :interface_neighbor_evidence_valid_protocol,
             check: "protocol IN ('lldp', 'cdp')"
           )

    create constraint(:interface_neighbor_evidence, :interface_neighbor_evidence_valid_id_kinds,
             check:
               "(remote_chassis_id_kind IS NULL OR remote_chassis_id_kind IN ('mac_address', 'network_address', 'local', 'name')) AND (remote_port_id_kind IS NULL OR remote_port_id_kind IN ('mac_address', 'local', 'name'))"
           )

    create constraint(:interface_neighbor_evidence, :interface_neighbor_evidence_valid_ttl,
             check: "ttl_seconds BETWEEN 1 AND 65535 AND expires_at > observed_at"
           )

    create constraint(:interface_neighbor_evidence, :interface_neighbor_evidence_stale_shape,
             check:
               "(stale_at IS NULL AND stale_reason IS NULL) OR (stale_at IS NOT NULL AND stale_reason IS NOT NULL AND stale_reason IN ('expired', 'superseded', 'withdrawn'))"
           )

    execute(
      """
      CREATE FUNCTION enforce_interface_neighbor_evidence_immutability() RETURNS trigger AS $$
      BEGIN
        IF (to_jsonb(NEW) - ARRAY['stale_at', 'stale_reason']) =
           (to_jsonb(OLD) - ARRAY['stale_at', 'stale_reason']) THEN
          RETURN NEW;
        END IF;

        RAISE EXCEPTION 'interface neighbor evidence facts are immutable'
          USING ERRCODE = 'integrity_constraint_violation';
      END;
      $$ LANGUAGE plpgsql
      """,
      "DROP FUNCTION enforce_interface_neighbor_evidence_immutability()"
    )

    execute(
      """
      CREATE TRIGGER interface_neighbor_evidence_enforce_immutability
      BEFORE UPDATE ON interface_neighbor_evidence
      FOR EACH ROW EXECUTE FUNCTION enforce_interface_neighbor_evidence_immutability()
      """,
      "DROP TRIGGER interface_neighbor_evidence_enforce_immutability ON interface_neighbor_evidence"
    )

    create table(:interface_neighbor_matches, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :organization_id, references(:organizations, on_delete: :delete_all, type: :binary_id),
        null: false

      add :interface_neighbor_evidence_id,
          references(:interface_neighbor_evidence,
            with: [organization_id: :organization_id],
            on_delete: :delete_all,
            type: :binary_id,
            name: :interface_neighbor_matches_tenant_evidence_fkey
          ),
          null: false

      add :remote_interface_id,
          references(:interfaces,
            with: [organization_id: :organization_id],
            on_delete: :delete_all,
            type: :binary_id,
            name: :interface_neighbor_matches_tenant_interface_fkey
          )

      add :status, :string, null: false
      add :strategy, :string
      add :candidate_count, :integer, null: false, default: 0
      timestamps(type: :"timestamp(3)")
    end

    create unique_index(
             :interface_neighbor_matches,
             [
               :organization_id,
               :interface_neighbor_evidence_id
             ],
             name: :interface_neighbor_matches_evidence_index
           )

    create constraint(:interface_neighbor_matches, :interface_neighbor_matches_status_shape,
             check:
               "(status = 'matched' AND remote_interface_id IS NOT NULL AND strategy IS NOT NULL AND candidate_count = 1) OR (status IN ('unresolved', 'ambiguous') AND remote_interface_id IS NULL AND strategy IS NULL AND candidate_count >= 0)"
           )

    create constraint(:interface_neighbor_matches, :interface_neighbor_matches_valid_strategy,
             check: "strategy IS NULL OR strategy IN ('stable_identifiers', 'name_fallback')"
           )

    create table(:current_interface_adjacencies, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :organization_id, references(:organizations, on_delete: :delete_all, type: :binary_id),
        null: false

      add :interface_a_id,
          references(:interfaces,
            with: [organization_id: :organization_id],
            on_delete: :delete_all,
            type: :binary_id,
            name: :current_interface_adjacencies_tenant_a_fkey
          ),
          null: false

      add :interface_b_id,
          references(:interfaces,
            with: [organization_id: :organization_id],
            on_delete: :delete_all,
            type: :binary_id,
            name: :current_interface_adjacencies_tenant_b_fkey
          ),
          null: false

      add :primary_evidence_id,
          references(:interface_neighbor_evidence,
            with: [organization_id: :organization_id],
            on_delete: :delete_all,
            type: :binary_id,
            name: :current_interface_adjacencies_tenant_evidence_fkey
          ),
          null: false

      add :confidence, :string, null: false
      add :last_observed_at, :"timestamp(3)", null: false
      add :metadata, :map, null: false, default: %{}
      timestamps(type: :"timestamp(3)")
    end

    create unique_index(
             :current_interface_adjacencies,
             [
               :organization_id,
               :interface_a_id,
               :interface_b_id
             ],
             name: :current_interface_adjacencies_endpoints_index
           )

    create unique_index(:current_interface_adjacencies, [:id, :organization_id])

    create index(:current_interface_adjacencies, [:organization_id, :interface_a_id],
             name: :current_interface_adjacencies_a_index
           )

    create index(:current_interface_adjacencies, [:organization_id, :interface_b_id],
             name: :current_interface_adjacencies_b_index
           )

    create constraint(
             :current_interface_adjacencies,
             :current_interface_adjacencies_canonical_order,
             check: "interface_a_id < interface_b_id"
           )

    create constraint(
             :current_interface_adjacencies,
             :current_interface_adjacencies_valid_confidence,
             check: "confidence IN ('reported', 'reciprocal')"
           )

    create table(:current_interface_adjacency_endpoints, primary_key: false) do
      add :organization_id,
          references(:organizations, on_delete: :delete_all, type: :binary_id),
          null: false,
          primary_key: true

      add :interface_id,
          references(:interfaces,
            with: [organization_id: :organization_id],
            on_delete: :delete_all,
            type: :binary_id,
            name: :current_interface_adjacency_endpoints_tenant_interface_fkey
          ),
          null: false,
          primary_key: true

      add :adjacency_id,
          references(:current_interface_adjacencies,
            with: [organization_id: :organization_id],
            on_delete: :delete_all,
            type: :binary_id,
            name: :current_interface_adjacency_endpoints_tenant_adjacency_fkey
          ),
          null: false
    end

    create index(:current_interface_adjacency_endpoints, [:adjacency_id, :organization_id])

    execute(
      """
      CREATE FUNCTION occupy_current_interface_adjacency_endpoints() RETURNS trigger AS $$
      BEGIN
        INSERT INTO current_interface_adjacency_endpoints
          (organization_id, interface_id, adjacency_id)
        VALUES
          (NEW.organization_id, NEW.interface_a_id, NEW.id),
          (NEW.organization_id, NEW.interface_b_id, NEW.id);

        RETURN NEW;
      END;
      $$ LANGUAGE plpgsql
      """,
      "DROP FUNCTION occupy_current_interface_adjacency_endpoints()"
    )

    execute(
      """
      CREATE TRIGGER current_interface_adjacencies_occupy_endpoints
      AFTER INSERT ON current_interface_adjacencies
      FOR EACH ROW EXECUTE FUNCTION occupy_current_interface_adjacency_endpoints()
      """,
      "DROP TRIGGER current_interface_adjacencies_occupy_endpoints ON current_interface_adjacencies"
    )

    execute(
      """
      CREATE FUNCTION enforce_current_interface_adjacency_occupancy() RETURNS trigger AS $$
      DECLARE
        checked_adjacency_id uuid;
        checked_organization_id uuid;
      BEGIN
        IF TG_OP IN ('DELETE', 'UPDATE') THEN
          checked_adjacency_id := OLD.adjacency_id;
          checked_organization_id := OLD.organization_id;

          IF EXISTS (
            SELECT 1
            FROM current_interface_adjacencies adjacency
            WHERE adjacency.id = checked_adjacency_id
              AND adjacency.organization_id = checked_organization_id
              AND (
                (SELECT count(*)
                 FROM current_interface_adjacency_endpoints endpoint
                 WHERE endpoint.adjacency_id = adjacency.id
                   AND endpoint.organization_id = adjacency.organization_id) <> 2
                OR NOT EXISTS (
                  SELECT 1 FROM current_interface_adjacency_endpoints endpoint
                  WHERE endpoint.adjacency_id = adjacency.id
                    AND endpoint.organization_id = adjacency.organization_id
                    AND endpoint.interface_id = adjacency.interface_a_id
                )
                OR NOT EXISTS (
                  SELECT 1 FROM current_interface_adjacency_endpoints endpoint
                  WHERE endpoint.adjacency_id = adjacency.id
                    AND endpoint.organization_id = adjacency.organization_id
                    AND endpoint.interface_id = adjacency.interface_b_id
                )
              )
          ) THEN
            RAISE EXCEPTION 'current interface adjacency occupancy is inconsistent'
              USING ERRCODE = 'integrity_constraint_violation';
          END IF;
        END IF;

        IF TG_OP IN ('INSERT', 'UPDATE') THEN
          checked_adjacency_id := NEW.adjacency_id;
          checked_organization_id := NEW.organization_id;

          IF EXISTS (
            SELECT 1
            FROM current_interface_adjacencies adjacency
            WHERE adjacency.id = checked_adjacency_id
              AND adjacency.organization_id = checked_organization_id
              AND (
                (SELECT count(*)
                 FROM current_interface_adjacency_endpoints endpoint
                 WHERE endpoint.adjacency_id = adjacency.id
                   AND endpoint.organization_id = adjacency.organization_id) <> 2
                OR NOT EXISTS (
                  SELECT 1 FROM current_interface_adjacency_endpoints endpoint
                  WHERE endpoint.adjacency_id = adjacency.id
                    AND endpoint.organization_id = adjacency.organization_id
                    AND endpoint.interface_id = adjacency.interface_a_id
                )
                OR NOT EXISTS (
                  SELECT 1 FROM current_interface_adjacency_endpoints endpoint
                  WHERE endpoint.adjacency_id = adjacency.id
                    AND endpoint.organization_id = adjacency.organization_id
                    AND endpoint.interface_id = adjacency.interface_b_id
                )
              )
          ) THEN
            RAISE EXCEPTION 'current interface adjacency occupancy is inconsistent'
              USING ERRCODE = 'integrity_constraint_violation';
          END IF;
        END IF;

        RETURN NULL;
      END;
      $$ LANGUAGE plpgsql
      """,
      "DROP FUNCTION enforce_current_interface_adjacency_occupancy()"
    )

    execute(
      """
      CREATE CONSTRAINT TRIGGER current_interface_adjacency_endpoints_enforce_consistency
      AFTER INSERT OR UPDATE OR DELETE ON current_interface_adjacency_endpoints
      DEFERRABLE INITIALLY DEFERRED
      FOR EACH ROW EXECUTE FUNCTION enforce_current_interface_adjacency_occupancy()
      """,
      "DROP TRIGGER current_interface_adjacency_endpoints_enforce_consistency ON current_interface_adjacency_endpoints"
    )

    execute(
      """
      CREATE FUNCTION enforce_current_interface_adjacency_endpoints_immutable() RETURNS trigger AS $$
      BEGIN
        IF NEW.organization_id = OLD.organization_id AND
           NEW.interface_a_id = OLD.interface_a_id AND
           NEW.interface_b_id = OLD.interface_b_id THEN
          RETURN NEW;
        END IF;

        RAISE EXCEPTION 'current interface adjacency endpoints are immutable'
          USING ERRCODE = 'integrity_constraint_violation';
      END;
      $$ LANGUAGE plpgsql
      """,
      "DROP FUNCTION enforce_current_interface_adjacency_endpoints_immutable()"
    )

    execute(
      """
      CREATE TRIGGER current_interface_adjacencies_enforce_endpoints_immutable
      BEFORE UPDATE ON current_interface_adjacencies
      FOR EACH ROW EXECUTE FUNCTION enforce_current_interface_adjacency_endpoints_immutable()
      """,
      "DROP TRIGGER current_interface_adjacencies_enforce_endpoints_immutable ON current_interface_adjacencies"
    )
  end
end
