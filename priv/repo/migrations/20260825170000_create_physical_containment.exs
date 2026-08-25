defmodule Renga.Repo.Migrations.CreatePhysicalContainment do
  use Ecto.Migration

  def up do
    execute "CREATE EXTENSION IF NOT EXISTS btree_gist"

    create_projection(:site_groups, fn ->
      add :parent_id, :binary_id
      add :description, :text
      add :metadata, :map, null: false, default: %{}
    end)

    create unique_index(:site_groups, [:id, :organization_id])

    alter table(:site_groups) do
      modify :parent_id,
             references(:site_groups,
               with: [organization_id: :organization_id],
               on_delete: :restrict,
               type: :binary_id,
               name: :site_groups_organization_parent_fkey
             )
    end

    create constraint(:site_groups, :site_groups_not_self_parent,
             check: "parent_id IS NULL OR parent_id <> id"
           )

    create index(:site_groups, [:organization_id, :parent_id])

    create_projection(:sites, fn ->
      add :site_group_id,
          references(:site_groups,
            with: [organization_id: :organization_id],
            on_delete: :restrict,
            type: :binary_id,
            name: :sites_organization_site_group_fkey
          )

      add :slug, :string, null: false
      add :status, :string, null: false, default: "active"
      add :description, :text
      add :physical_address, :text
      add :time_zone, :string
      add :metadata, :map, null: false, default: %{}
    end)

    create unique_index(:sites, [:id, :organization_id])
    create unique_index(:sites, [:organization_id, :slug])
    create index(:sites, [:organization_id, :site_group_id])

    create_projection(:locations, fn ->
      add :site_id,
          references(:sites,
            with: [organization_id: :organization_id],
            on_delete: :restrict,
            type: :binary_id,
            name: :locations_organization_site_fkey
          ),
          null: false

      add :parent_id, :binary_id
      add :kind, :string
      add :status, :string, null: false, default: "active"
      add :description, :text
      add :metadata, :map, null: false, default: %{}
    end)

    create unique_index(:locations, [:id, :organization_id])
    create unique_index(:locations, [:id, :organization_id, :site_id])

    alter table(:locations) do
      modify :parent_id,
             references(:locations,
               with: [organization_id: :organization_id, site_id: :site_id],
               on_delete: :restrict,
               type: :binary_id,
               name: :locations_site_parent_fkey
             )
    end

    create constraint(:locations, :locations_not_self_parent,
             check: "parent_id IS NULL OR parent_id <> id"
           )

    create index(:locations, [:organization_id, :site_id, :parent_id])

    create_projection(:racks, fn ->
      add :site_id,
          references(:sites,
            with: [organization_id: :organization_id],
            on_delete: :restrict,
            type: :binary_id,
            name: :racks_organization_site_fkey
          ),
          null: false

      add :location_id,
          references(:locations,
            with: [organization_id: :organization_id, site_id: :site_id],
            on_delete: :restrict,
            type: :binary_id,
            name: :racks_site_location_fkey
          )

      add :status, :string, null: false, default: "active"
      add :facility_id, :string
      add :height_units, :integer, null: false, default: 42
      add :width, :string, null: false, default: "19_inch"
      add :starting_unit, :string, null: false, default: "bottom"
      add :outer_width, :decimal
      add :outer_depth, :decimal
      add :dimension_unit, :string
      add :metadata, :map, null: false, default: %{}
    end)

    create unique_index(:racks, [:id, :organization_id])
    create unique_index(:racks, [:id, :organization_id, :site_id])
    create index(:racks, [:organization_id, :site_id, :location_id])

    create constraint(:racks, :racks_valid_geometry,
             check:
               "height_units > 0 AND (outer_width IS NULL OR outer_width > 0) AND (outer_depth IS NULL OR outer_depth > 0)"
           )

    create_placement(:desired_placements)
    create_placement(:current_placements)

    create table(:rack_occupancies, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :organization_id, :binary_id, null: false

      add :current_placement_id,
          references(:current_placements,
            with: [organization_id: :organization_id],
            on_delete: :delete_all,
            type: :binary_id,
            name: :rack_occupancies_placement_fkey
          ),
          null: false

      add :rack_id,
          references(:racks,
            with: [organization_id: :organization_id],
            on_delete: :delete_all,
            type: :binary_id,
            name: :rack_occupancies_rack_fkey
          ),
          null: false

      add :face, :string, null: false
      add :units, :int4range, null: false
      timestamps(type: :"timestamp(3)")
    end

    create unique_index(:rack_occupancies, [:current_placement_id, :face])
    create index(:rack_occupancies, [:organization_id, :rack_id])

    execute """
    ALTER TABLE rack_occupancies
    ADD CONSTRAINT rack_occupancies_no_overlap
    EXCLUDE USING gist (rack_id WITH =, face WITH =, units WITH &&)
    """

    create table(:placement_evidence, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :organization_id, :binary_id, null: false
      add :source_id, :binary_id, null: false
      add :observation_id, :binary_id, null: false

      add :resource_id,
          references(:resources,
            with: [organization_id: :organization_id],
            on_delete: :delete_all,
            type: :binary_id,
            name: :placement_evidence_resource_fkey
          ),
          null: false

      add :site_identifier, :string
      add :location_identifier, :string
      add :rack_identifier, :string
      add :position, :integer
      add :height_units, :integer
      add :face, :string
      add :confidence, :integer, null: false, default: 50
      add :observed_at, :"timestamp(3)", null: false
      add :stale_at, :"timestamp(3)"
      add :metadata, :map, null: false, default: %{}
      timestamps(type: :"timestamp(3)", updated_at: false)
    end

    execute """
    ALTER TABLE placement_evidence
    ADD CONSTRAINT placement_evidence_source_observation_fkey
    FOREIGN KEY (observation_id, organization_id, source_id)
    REFERENCES observations(id, organization_id, source_id) ON DELETE CASCADE
    """

    create index(:placement_evidence, [:organization_id, :resource_id, :observed_at])
    create index(:placement_evidence, [:organization_id, :source_id, :observation_id])

    create table(:placement_findings, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :organization_id, :binary_id, null: false

      add :resource_id,
          references(:resources,
            with: [organization_id: :organization_id],
            on_delete: :delete_all,
            type: :binary_id,
            name: :placement_findings_resource_fkey
          ),
          null: false

      add :kind, :string, null: false
      add :status, :string, null: false, default: "open"
      add :message, :text, null: false
      add :details, :map, null: false, default: %{}
      add :resolved_at, :"timestamp(3)"
      timestamps(type: :"timestamp(3)")
    end

    create unique_index(:placement_findings, [:organization_id, :resource_id, :kind],
             where: "status = 'open'",
             name: :placement_findings_open_kind_index
           )

    create index(:placement_findings, [:organization_id, :status, :kind])
  end

  def down do
    drop table(:placement_findings)
    drop table(:placement_evidence)
    drop table(:rack_occupancies)
    drop table(:current_placements)
    drop table(:desired_placements)
    drop table(:racks)
    drop table(:locations)
    drop table(:sites)
    drop table(:site_groups)
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

  defp create_placement(table_name) do
    create table(table_name, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :organization_id, :binary_id, null: false

      add :resource_id,
          references(:resources,
            with: [organization_id: :organization_id],
            on_delete: :delete_all,
            type: :binary_id,
            name: :"#{table_name}_resource_fkey"
          ),
          null: false

      add :site_id,
          references(:sites,
            with: [organization_id: :organization_id],
            on_delete: :restrict,
            type: :binary_id,
            name: :"#{table_name}_site_fkey"
          ),
          null: false

      add :location_id,
          references(:locations,
            with: [organization_id: :organization_id, site_id: :site_id],
            on_delete: :restrict,
            type: :binary_id,
            name: :"#{table_name}_location_fkey"
          )

      add :rack_id,
          references(:racks,
            with: [organization_id: :organization_id, site_id: :site_id],
            on_delete: :restrict,
            type: :binary_id,
            name: :"#{table_name}_rack_fkey"
          )

      add :position, :integer
      add :height_units, :integer
      add :face, :string
      add :confirmed, :boolean, null: false, default: false
      add :provenance, :map, null: false, default: %{}
      timestamps(type: :"timestamp(3)")
    end

    create unique_index(table_name, [:id, :organization_id])
    create unique_index(table_name, [:organization_id, :resource_id])

    create constraint(table_name, :"#{table_name}_valid_rack_position",
             check:
               "(rack_id IS NULL AND position IS NULL AND height_units IS NULL AND face IS NULL) OR " <>
                 "(rack_id IS NOT NULL AND ((position IS NULL AND height_units IS NULL AND face IS NULL) OR " <>
                 "(position > 0 AND height_units > 0 AND face IN ('front', 'rear', 'full'))))"
           )
  end
end
