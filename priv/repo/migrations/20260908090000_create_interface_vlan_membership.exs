defmodule Renga.Repo.Migrations.CreateInterfaceVlanMembership do
  use Ecto.Migration

  def change do
    create_membership_table(:desired_interface_vlan_assignments)
    create_membership_table(:current_interface_vlan_memberships)
    create_mode_table(:desired_interface_vlan_modes)
    create_mode_table(:current_interface_vlan_modes)

    create table(:source_vlan_group_mappings, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :organization_id, references(:organizations, on_delete: :delete_all, type: :binary_id),
        null: false

      add :source_id,
          references(:sources,
            with: [organization_id: :organization_id],
            on_delete: :delete_all,
            type: :binary_id,
            name: :source_vlan_group_mappings_tenant_source_fkey
          ),
          null: false

      add :vlan_group_id,
          references(:vlan_groups,
            with: [organization_id: :organization_id],
            on_delete: :restrict,
            type: :binary_id,
            name: :source_vlan_group_mappings_tenant_group_fkey
          )

      add :source_local_scope, :string, null: false, default: "default"
      add :metadata, :map, null: false, default: %{}
      timestamps(type: :"timestamp(3)")
    end

    create unique_index(:source_vlan_group_mappings, [:id, :organization_id])

    create unique_index(
             :source_vlan_group_mappings,
             [:organization_id, :source_id, :source_local_scope],
             name: :source_vlan_group_mappings_source_scope_index
           )

    create table(:interface_vlan_evidence, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :organization_id, references(:organizations, on_delete: :delete_all, type: :binary_id),
        null: false

      add :interface_id,
          references(:interfaces,
            with: [organization_id: :organization_id],
            on_delete: :delete_all,
            type: :binary_id,
            name: :interface_vlan_evidence_tenant_interface_fkey
          ),
          null: false

      add :vlan_id,
          references(:vlans,
            with: [organization_id: :organization_id],
            on_delete: :restrict,
            type: :binary_id,
            name: :interface_vlan_evidence_tenant_vlan_fkey
          )

      add :source_id,
          references(:sources,
            with: [organization_id: :organization_id],
            on_delete: :restrict,
            type: :binary_id,
            name: :interface_vlan_evidence_tenant_source_fkey
          ),
          null: false

      add :observation_id,
          references(:observations,
            with: [organization_id: :organization_id, source_id: :source_id],
            on_delete: :restrict,
            type: :binary_id,
            name: :interface_vlan_evidence_tenant_observation_fkey
          ),
          null: false

      add :source_local_key, :string, null: false
      add :source_local_scope, :string
      add :vid, :integer, null: false
      add :tagging_mode, :string, null: false
      add :metadata, :map, null: false, default: %{}
      add :observed_at, :"timestamp(3)", null: false
      add :stale_at, :"timestamp(3)"
      timestamps(type: :"timestamp(3)", updated_at: false)
    end

    create unique_index(
             :interface_vlan_evidence,
             [:id, :organization_id, :interface_id, :vlan_id],
             name: :interface_vlan_evidence_membership_identity_index
           )

    create unique_index(
             :interface_vlan_evidence,
             [:organization_id, :observation_id, :interface_id, :source_local_key],
             name: :interface_vlan_evidence_observation_link_index
           )

    create index(:interface_vlan_evidence, [:organization_id, :source_id, :interface_id],
             name: :interface_vlan_evidence_source_interface_index
           )

    create constraint(:interface_vlan_evidence, :interface_vlan_evidence_valid_vid,
             check: "vid BETWEEN 1 AND 4094"
           )

    create constraint(:interface_vlan_evidence, :interface_vlan_evidence_valid_tagging_mode,
             check: "tagging_mode IN ('tagged', 'untagged')"
           )

    create table(:interface_vlan_mode_evidence, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :organization_id, references(:organizations, on_delete: :delete_all, type: :binary_id),
        null: false

      add :interface_id,
          references(:interfaces,
            with: [organization_id: :organization_id],
            on_delete: :delete_all,
            type: :binary_id,
            name: :interface_vlan_mode_evidence_tenant_interface_fkey
          ),
          null: false

      add :source_id,
          references(:sources,
            with: [organization_id: :organization_id],
            on_delete: :restrict,
            type: :binary_id,
            name: :interface_vlan_mode_evidence_tenant_source_fkey
          ),
          null: false

      add :observation_id,
          references(:observations,
            with: [organization_id: :organization_id, source_id: :source_id],
            on_delete: :restrict,
            type: :binary_id,
            name: :interface_vlan_mode_evidence_tenant_observation_fkey
          ),
          null: false

      add :mode, :string
      add :observed_at, :"timestamp(3)", null: false
      add :metadata, :map, null: false, default: %{}
      timestamps(type: :"timestamp(3)", updated_at: false)
    end

    create unique_index(
             :interface_vlan_mode_evidence,
             [:id, :organization_id, :interface_id],
             name: :interface_vlan_mode_evidence_projection_identity_index
           )

    create unique_index(
             :interface_vlan_mode_evidence,
             [:organization_id, :observation_id, :interface_id],
             name: :interface_vlan_mode_evidence_observation_link_index
           )

    create index(:interface_vlan_mode_evidence, [:organization_id, :source_id, :interface_id],
             name: :interface_vlan_mode_evidence_source_interface_index
           )

    create constraint(:interface_vlan_mode_evidence, :interface_vlan_mode_evidence_valid_mode,
             check: "mode IS NULL OR mode IN ('access', 'trunk', 'tagged_all')"
           )

    alter table(:current_interface_vlan_memberships) do
      add :interface_vlan_evidence_id,
          references(:interface_vlan_evidence,
            with: [
              organization_id: :organization_id,
              interface_id: :interface_id,
              vlan_id: :vlan_id
            ],
            on_delete: :delete_all,
            type: :binary_id,
            name: :current_interface_vlan_memberships_tenant_evidence_fkey
          ),
          null: false
    end

    alter table(:current_interface_vlan_modes) do
      add :interface_vlan_mode_evidence_id,
          references(:interface_vlan_mode_evidence,
            with: [organization_id: :organization_id, interface_id: :interface_id],
            on_delete: :delete_all,
            type: :binary_id,
            name: :current_interface_vlan_modes_tenant_evidence_fkey
          ),
          null: false
    end

    alter table(:interface_relationship_evidence) do
      add :stale_at, :"timestamp(3)"
    end

    create table(:topology_findings, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :organization_id, references(:organizations, on_delete: :delete_all, type: :binary_id),
        null: false

      add :interface_id,
          references(:interfaces,
            with: [organization_id: :organization_id],
            on_delete: :delete_all,
            type: :binary_id,
            name: :topology_findings_tenant_interface_fkey
          ),
          null: false

      add :kind, :string, null: false
      add :resolution_key, :string, null: false
      add :status, :string, null: false, default: "open"
      add :message, :text, null: false
      add :details, :map, null: false, default: %{}
      add :last_observed_at, :"timestamp(3)", null: false
      add :resolved_at, :"timestamp(3)"
      timestamps(type: :"timestamp(3)")
    end

    create unique_index(
             :topology_findings,
             [:organization_id, :interface_id, :kind, :resolution_key],
             where: "status = 'open'",
             name: :topology_findings_open_resolution_index
           )

    create index(:topology_findings, [:organization_id, :status, :kind])

    create constraint(:topology_findings, :topology_findings_valid_status,
             check: "status IN ('open', 'resolved')"
           )

    create constraint(:topology_findings, :topology_findings_resolution_state,
             check:
               "(status = 'open' AND resolved_at IS NULL) OR (status = 'resolved' AND resolved_at IS NOT NULL)"
           )
  end

  defp create_membership_table(table) do
    create table(table, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :organization_id, references(:organizations, on_delete: :delete_all, type: :binary_id),
        null: false

      add :interface_id,
          references(:interfaces,
            with: [organization_id: :organization_id],
            on_delete: :delete_all,
            type: :binary_id,
            name: :"#{table}_tenant_interface_fkey"
          ),
          null: false

      add :vlan_id,
          references(:vlans,
            with: [organization_id: :organization_id],
            on_delete: :restrict,
            type: :binary_id,
            name: :"#{table}_tenant_vlan_fkey"
          ),
          null: false

      add :tagging_mode, :string, null: false
      add :metadata, :map, null: false, default: %{}
      timestamps(type: :"timestamp(3)")
    end

    create unique_index(table, [:id, :organization_id])

    create unique_index(table, [:organization_id, :interface_id, :vlan_id],
             name: :"#{table}_interface_vlan_index"
           )

    create unique_index(table, [:organization_id, :interface_id],
             where: "tagging_mode = 'untagged'",
             name: :"#{table}_effective_untagged_index"
           )

    create constraint(table, :"#{table}_valid_tagging_mode",
             check: "tagging_mode IN ('tagged', 'untagged')"
           )
  end

  defp create_mode_table(table) do
    create table(table, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :organization_id, references(:organizations, on_delete: :delete_all, type: :binary_id),
        null: false

      add :interface_id,
          references(:interfaces,
            with: [organization_id: :organization_id],
            on_delete: :delete_all,
            type: :binary_id,
            name: :"#{table}_tenant_interface_fkey"
          ),
          null: false

      add :mode, :string, null: false
      add :metadata, :map, null: false, default: %{}
      timestamps(type: :"timestamp(3)")
    end

    create unique_index(table, [:organization_id, :interface_id])

    create constraint(table, :"#{table}_valid_mode",
             check: "mode IN ('access', 'trunk', 'tagged_all')"
           )
  end
end
