defmodule Renga.Repo.Migrations.CreateInventoryInterfaceRelationships do
  use Ecto.Migration

  def change do
    create table(:interface_relationships, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :organization_id, references(:organizations, on_delete: :delete_all, type: :binary_id),
        null: false

      add :source_interface_id,
          references(:interfaces,
            with: [organization_id: :organization_id],
            on_delete: :delete_all,
            type: :binary_id,
            name: :interface_relationships_tenant_source_fkey
          ),
          null: false

      add :target_interface_id,
          references(:interfaces,
            with: [organization_id: :organization_id],
            on_delete: :delete_all,
            type: :binary_id,
            name: :interface_relationships_tenant_target_fkey
          ),
          null: false

      add :kind, :string, null: false
      add :metadata, :map, null: false, default: %{}

      timestamps(type: :"timestamp(3)")
    end

    create index(:interface_relationships, [:organization_id, :source_interface_id],
             name: :interface_relationships_org_source_interface_index
           )

    create unique_index(:interface_relationships, [:id, :organization_id])

    create constraint(:interface_relationships, :interface_relationships_distinct_endpoints,
             check: "source_interface_id <> target_interface_id"
           )

    create index(:interface_relationships, [:organization_id, :target_interface_id],
             name: :interface_relationships_org_target_interface_index
           )

    create index(:interface_relationships, [:organization_id, :kind])

    create unique_index(
             :interface_relationships,
             [
               :organization_id,
               :source_interface_id,
               :target_interface_id,
               :kind
             ],
             name: :interface_relationships_source_target_kind_index
           )

    create table(:interface_evidence, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :organization_id, references(:organizations, on_delete: :delete_all, type: :binary_id),
        null: false

      add :interface_id,
          references(:interfaces,
            with: [organization_id: :organization_id],
            on_delete: :delete_all,
            type: :binary_id,
            name: :interface_evidence_tenant_interface_fkey
          ),
          null: false

      add :source_id,
          references(:sources,
            with: [organization_id: :organization_id],
            on_delete: :restrict,
            type: :binary_id,
            name: :interface_evidence_tenant_source_fkey
          ),
          null: false

      add :observation_id,
          references(:observations,
            with: [organization_id: :organization_id, source_id: :source_id],
            on_delete: :restrict,
            type: :binary_id,
            name: :interface_evidence_tenant_fkey
          ),
          null: false

      add :name, :string, null: false
      add :mac_address, :macaddr
      add :kind, :string, null: false
      add :status, :string, null: false
      add :mtu, :integer
      add :speed_mbps, :integer
      add :metadata, :map, null: false, default: %{}
      add :observed_at, :"timestamp(3)", null: false

      timestamps(type: :"timestamp(3)")
    end

    create unique_index(:interface_evidence, [:organization_id, :observation_id, :interface_id],
             name: :interface_evidence_observation_link_index
           )

    create index(:interface_evidence, [:organization_id, :source_id, :interface_id])

    create constraint(:interface_evidence, :interface_evidence_mtu_speed_positive,
             check: "(mtu IS NULL OR mtu > 0) AND (speed_mbps IS NULL OR speed_mbps > 0)"
           )

    create table(:address_evidence, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :organization_id, references(:organizations, on_delete: :delete_all, type: :binary_id),
        null: false

      add :address_id,
          references(:addresses,
            with: [organization_id: :organization_id],
            on_delete: :delete_all,
            type: :binary_id,
            name: :address_evidence_tenant_address_fkey
          ),
          null: false

      add :source_id,
          references(:sources,
            with: [organization_id: :organization_id],
            on_delete: :restrict,
            type: :binary_id,
            name: :address_evidence_tenant_source_fkey
          ),
          null: false

      add :observation_id,
          references(:observations,
            with: [organization_id: :organization_id, source_id: :source_id],
            on_delete: :restrict,
            type: :binary_id,
            name: :address_evidence_tenant_observation_fkey
          ),
          null: false

      add :address, :inet, null: false
      add :scope, :string
      add :metadata, :map, null: false, default: %{}
      add :observed_at, :"timestamp(3)", null: false

      timestamps(type: :"timestamp(3)")
    end

    create unique_index(:address_evidence, [:organization_id, :observation_id, :address_id],
             name: :address_evidence_observation_link_index
           )

    create index(:address_evidence, [:organization_id, :source_id, :address_id])

    create table(:interface_relationship_evidence, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :organization_id, references(:organizations, on_delete: :delete_all, type: :binary_id),
        null: false

      add :interface_relationship_id,
          references(:interface_relationships,
            with: [organization_id: :organization_id],
            on_delete: :delete_all,
            type: :binary_id,
            name: :interface_relationship_evidence_tenant_relationship_fkey
          ),
          null: false

      add :source_id,
          references(:sources,
            with: [organization_id: :organization_id],
            on_delete: :restrict,
            type: :binary_id,
            name: :interface_relationship_evidence_tenant_source_fkey
          ),
          null: false

      add :observation_id,
          references(:observations,
            with: [organization_id: :organization_id, source_id: :source_id],
            on_delete: :restrict,
            type: :binary_id,
            name: :interface_relationship_evidence_tenant_observation_fkey
          ),
          null: false

      add :kind, :string, null: false
      add :metadata, :map, null: false, default: %{}
      add :observed_at, :"timestamp(3)", null: false

      timestamps(type: :"timestamp(3)")
    end

    create unique_index(
             :interface_relationship_evidence,
             [:organization_id, :observation_id, :interface_relationship_id],
             name: :interface_relationship_evidence_observation_link_index
           )

    create index(
             :interface_relationship_evidence,
             [:organization_id, :source_id, :interface_relationship_id],
             name: :interface_relationship_evidence_source_link_index
           )

    create table(:resource_relationships, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :organization_id, references(:organizations, on_delete: :delete_all, type: :binary_id),
        null: false

      add :source_resource_id,
          references(:resources,
            with: [organization_id: :organization_id],
            on_delete: :delete_all,
            type: :binary_id,
            name: :resource_relationships_tenant_source_fkey
          ),
          null: false

      add :target_resource_id,
          references(:resources,
            with: [organization_id: :organization_id],
            on_delete: :delete_all,
            type: :binary_id,
            name: :resource_relationships_tenant_endpoints_fkey
          ),
          null: false

      add :kind, :string, null: false
      add :metadata, :map, null: false, default: %{}

      timestamps(type: :"timestamp(3)")
    end

    create unique_index(
             :resource_relationships,
             [:organization_id, :source_resource_id, :target_resource_id, :kind],
             name: :resource_relationships_source_target_kind_index
           )

    create index(:resource_relationships, [:organization_id, :target_resource_id])

    create constraint(:resource_relationships, :resource_relationships_distinct_endpoints,
             check: "source_resource_id <> target_resource_id"
           )

    create table(:resource_owners, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :organization_id, references(:organizations, on_delete: :delete_all, type: :binary_id),
        null: false

      add :owner_resource_id,
          references(:resources,
            with: [organization_id: :organization_id],
            on_delete: :delete_all,
            type: :binary_id,
            name: :resource_owners_tenant_owner_fkey
          ),
          null: false

      add :child_resource_id,
          references(:resources,
            with: [organization_id: :organization_id],
            on_delete: :delete_all,
            type: :binary_id,
            name: :resource_owners_tenant_child_fkey
          ),
          null: false

      add :kind, :string, null: false
      add :controller, :boolean, null: false, default: true
      add :metadata, :map, null: false, default: %{}

      timestamps(type: :"timestamp(3)")
    end

    create unique_index(
             :resource_owners,
             [:organization_id, :owner_resource_id, :child_resource_id, :kind],
             name: :resource_owners_owner_child_kind_index
           )

    create constraint(:resource_owners, :resource_owners_distinct_endpoints,
             check: "owner_resource_id <> child_resource_id"
           )

    create unique_index(:resource_owners, [:organization_id, :child_resource_id],
             where: "controller = true",
             name: :resource_owners_child_controller_index
           )
  end
end
