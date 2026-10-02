defmodule Renga.Repo.Migrations.CreatePrefixVlanRelationships do
  @moduledoc """
  Optional tenant-safe many-to-many association between IPAM prefixes and VLANs.

  Neither side owns the other: both foreign keys are organization-scoped so a
  relationship cannot cross tenants, and deleting either endpoint only removes
  the association rows.
  """

  use Ecto.Migration

  def change do
    # The composite tenant foreign keys below need a unique (id, organization_id)
    # key on prefixes, mirroring the identity indexes other tenant-owned tables
    # already expose.
    create unique_index(:prefixes, [:id, :organization_id])

    create table(:prefix_vlan_relationships, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :organization_id, references(:organizations, on_delete: :delete_all, type: :binary_id),
        null: false

      add :prefix_id,
          references(:prefixes,
            with: [organization_id: :organization_id],
            on_delete: :delete_all,
            type: :binary_id,
            name: :prefix_vlan_relationships_tenant_prefix_fkey
          ),
          null: false

      add :vlan_id,
          references(:vlans,
            with: [organization_id: :organization_id],
            on_delete: :delete_all,
            type: :binary_id,
            name: :prefix_vlan_relationships_tenant_vlan_fkey
          ),
          null: false

      timestamps(type: :"timestamp(3)")
    end

    create unique_index(:prefix_vlan_relationships, [:id, :organization_id])

    create unique_index(:prefix_vlan_relationships, [:organization_id, :prefix_id, :vlan_id],
             name: :prefix_vlan_relationships_prefix_vlan_index
           )

    create index(:prefix_vlan_relationships, [:organization_id, :vlan_id],
             name: :prefix_vlan_relationships_vlan_index
           )
  end
end
