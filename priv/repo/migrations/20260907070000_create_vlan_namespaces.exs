defmodule Renga.Repo.Migrations.CreateVlanNamespaces do
  use Ecto.Migration

  def up do
    execute "CREATE EXTENSION IF NOT EXISTS btree_gist"

    create_projection(:vlan_groups, fn ->
      add :slug, :string, null: false
      add :scope_kind, :string, null: false, default: "global"

      add :site_id,
          references(:sites,
            with: [organization_id: :organization_id],
            on_delete: :restrict,
            type: :binary_id,
            name: :vlan_groups_organization_site_fkey
          )

      add :location_id,
          references(:locations,
            with: [organization_id: :organization_id],
            on_delete: :restrict,
            type: :binary_id,
            name: :vlan_groups_organization_location_fkey
          )

      add :status, :string, null: false, default: "active"
      add :description, :text
      add :metadata, :map, null: false, default: %{}
    end)

    create unique_index(:vlan_groups, [:id, :organization_id])
    create unique_index(:vlan_groups, [:organization_id, :slug])

    create index(:vlan_groups, [:organization_id, :scope_kind, :site_id, :location_id],
             name: :vlan_groups_scope_index
           )

    create constraint(:vlan_groups, :vlan_groups_valid_scope,
             check:
               "(scope_kind = 'global' AND site_id IS NULL AND location_id IS NULL) OR " <>
                 "(scope_kind = 'site' AND site_id IS NOT NULL AND location_id IS NULL) OR " <>
                 "(scope_kind = 'location' AND site_id IS NULL AND location_id IS NOT NULL)"
           )

    create table(:vlan_group_vid_ranges, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :organization_id, :binary_id, null: false

      add :vlan_group_id,
          references(:vlan_groups,
            with: [organization_id: :organization_id],
            on_delete: :delete_all,
            type: :binary_id,
            name: :vlan_group_vid_ranges_group_fkey
          ),
          null: false

      add :start_vid, :integer, null: false
      add :end_vid, :integer, null: false
      timestamps(type: :"timestamp(3)")
    end

    create index(:vlan_group_vid_ranges, [:organization_id, :vlan_group_id])

    create constraint(:vlan_group_vid_ranges, :vlan_group_vid_ranges_valid_bounds,
             check:
               "start_vid BETWEEN 1 AND 4094 AND end_vid BETWEEN 1 AND 4094 AND start_vid <= end_vid"
           )

    execute """
    ALTER TABLE vlan_group_vid_ranges
    ADD CONSTRAINT vlan_group_vid_ranges_no_overlap
    EXCLUDE USING gist (
      vlan_group_id WITH =,
      int4range(start_vid, end_vid, '[]') WITH &&
    )
    """

    create_projection(:vlans, fn ->
      add :vlan_group_id,
          references(:vlan_groups,
            with: [organization_id: :organization_id],
            on_delete: :restrict,
            type: :binary_id,
            name: :vlans_organization_group_fkey
          )

      add :vid, :integer, null: false
      add :name, :string, null: false
      add :status, :string, null: false, default: "active"
      add :role, :string
      add :description, :text
      add :metadata, :map, null: false, default: %{}
    end)

    create unique_index(:vlans, [:id, :organization_id])
    create index(:vlans, [:organization_id, :vlan_group_id])
    create constraint(:vlans, :vlans_valid_vid, check: "vid BETWEEN 1 AND 4094")

    execute """
    CREATE UNIQUE INDEX vlans_organization_group_vid_index
    ON vlans (organization_id, vlan_group_id, vid) NULLS NOT DISTINCT
    """
  end

  def down do
    drop table(:vlans)
    drop table(:vlan_group_vid_ranges)
    drop table(:vlan_groups)
  end

  defp create_projection(table_name, fields) do
    create table(table_name, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :organization_id, :binary_id, null: false

      add :resource_id,
          references(:resources,
            with: [organization_id: :organization_id],
            on_delete: :delete_all,
            type: :binary_id,
            name: :"#{table_name}_organization_resource_fkey"
          ),
          null: false

      fields.()
      timestamps(type: :"timestamp(3)")
    end

    create unique_index(table_name, [:organization_id, :resource_id])
  end
end
