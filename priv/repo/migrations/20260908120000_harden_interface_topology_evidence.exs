defmodule Renga.Repo.Migrations.HardenInterfaceTopologyEvidence do
  use Ecto.Migration

  def up do
    create table(:topology_snapshot_events, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :organization_id, references(:organizations, on_delete: :delete_all, type: :binary_id),
        null: false

      add :resource_id,
          references(:resources,
            with: [organization_id: :organization_id],
            on_delete: :delete_all,
            type: :binary_id,
            name: :topology_snapshot_events_tenant_resource_fkey
          ),
          null: false

      add :source_id,
          references(:sources,
            with: [organization_id: :organization_id],
            on_delete: :restrict,
            type: :binary_id,
            name: :topology_snapshot_events_tenant_source_fkey
          ),
          null: false

      add :observation_id,
          references(:observations,
            with: [organization_id: :organization_id, source_id: :source_id],
            on_delete: :restrict,
            type: :binary_id,
            name: :topology_snapshot_events_tenant_observation_fkey
          ),
          null: false

      add :section, :string, null: false
      add :observed_at, :"timestamp(3)", null: false
      timestamps(type: :"timestamp(3)", updated_at: false)
    end

    create unique_index(
             :topology_snapshot_events,
             [:organization_id, :observation_id, :resource_id, :section],
             name: :topology_snapshot_events_observation_section_index
           )

    execute """
    CREATE INDEX topology_snapshot_events_source_resource_section_index
    ON topology_snapshot_events
      (organization_id, resource_id, section, source_id,
       observed_at DESC, observation_id DESC)
    """

    create constraint(:topology_snapshot_events, :topology_snapshot_events_valid_section,
             check: "section IN ('interface_vlans', 'interface_relationships')"
           )

    execute """
    CREATE FUNCTION enforce_interface_vlan_evidence_immutability() RETURNS trigger AS $$
    BEGIN
      IF NEW.id IS NOT DISTINCT FROM OLD.id
         AND NEW.organization_id IS NOT DISTINCT FROM OLD.organization_id
         AND NEW.interface_id IS NOT DISTINCT FROM OLD.interface_id
         AND NEW.vlan_id IS NOT DISTINCT FROM OLD.vlan_id
         AND NEW.source_id IS NOT DISTINCT FROM OLD.source_id
         AND NEW.observation_id IS NOT DISTINCT FROM OLD.observation_id
         AND NEW.source_local_key IS NOT DISTINCT FROM OLD.source_local_key
         AND NEW.source_local_scope IS NOT DISTINCT FROM OLD.source_local_scope
         AND NEW.vid IS NOT DISTINCT FROM OLD.vid
         AND NEW.tagging_mode IS NOT DISTINCT FROM OLD.tagging_mode
         AND NEW.metadata IS NOT DISTINCT FROM OLD.metadata
         AND NEW.observed_at IS NOT DISTINCT FROM OLD.observed_at
         AND NEW.inserted_at IS NOT DISTINCT FROM OLD.inserted_at THEN
        RETURN NEW;
      END IF;

      RAISE EXCEPTION 'interface VLAN evidence facts are immutable'
        USING ERRCODE = 'integrity_constraint_violation';
    END;
    $$ LANGUAGE plpgsql
    """

    execute """
    CREATE TRIGGER interface_vlan_evidence_enforce_immutability
    BEFORE UPDATE ON interface_vlan_evidence
    FOR EACH ROW EXECUTE FUNCTION enforce_interface_vlan_evidence_immutability()
    """

    execute """
    CREATE FUNCTION reject_interface_vlan_mode_evidence_update() RETURNS trigger AS $$
    BEGIN
      RAISE EXCEPTION 'interface VLAN mode evidence is immutable'
        USING ERRCODE = 'integrity_constraint_violation';
    END;
    $$ LANGUAGE plpgsql
    """

    execute """
    CREATE TRIGGER interface_vlan_mode_evidence_reject_update
    BEFORE UPDATE ON interface_vlan_mode_evidence
    FOR EACH ROW EXECUTE FUNCTION reject_interface_vlan_mode_evidence_update()
    """

    execute """
    CREATE FUNCTION reject_topology_snapshot_event_update() RETURNS trigger AS $$
    BEGIN
      RAISE EXCEPTION 'topology snapshot events are immutable'
        USING ERRCODE = 'integrity_constraint_violation';
    END;
    $$ LANGUAGE plpgsql
    """

    execute """
    CREATE TRIGGER topology_snapshot_events_reject_update
    BEFORE UPDATE ON topology_snapshot_events
    FOR EACH ROW EXECUTE FUNCTION reject_topology_snapshot_event_update()
    """
  end

  def down do
    execute "DROP TRIGGER IF EXISTS topology_snapshot_events_reject_update ON topology_snapshot_events"
    execute "DROP FUNCTION IF EXISTS reject_topology_snapshot_event_update()"

    execute "DROP TRIGGER interface_vlan_mode_evidence_reject_update ON interface_vlan_mode_evidence"

    execute "DROP FUNCTION reject_interface_vlan_mode_evidence_update()"
    execute "DROP TRIGGER interface_vlan_evidence_enforce_immutability ON interface_vlan_evidence"
    execute "DROP FUNCTION enforce_interface_vlan_evidence_immutability()"

    execute "DROP INDEX topology_snapshot_events_source_resource_section_index"
    drop table(:topology_snapshot_events)
  end
end
