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
      ALTER TABLE topology_snapshot_events
      DROP CONSTRAINT topology_snapshot_events_valid_section,
      ADD CONSTRAINT topology_snapshot_events_valid_section
      CHECK (section IN ('interface_vlans', 'interface_relationships'))
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
      add :remote_system_name, :string
      add :remote_port_id, :string, null: false
      add :remote_port_id_kind, :string
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
               :remote_chassis_id,
               :remote_port_id
             ],
             name: :interface_neighbor_evidence_observation_endpoint_index
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
               "(stale_at IS NULL AND stale_reason IS NULL) OR (stale_at IS NOT NULL AND stale_reason IN ('expired', 'superseded', 'withdrawn'))"
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
  end
end
