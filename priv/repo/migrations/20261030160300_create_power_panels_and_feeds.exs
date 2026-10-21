defmodule Renga.Repo.Migrations.CreatePowerPanelsAndFeeds do
  use Ecto.Migration

  # RFD 10 phase 1: power panels at a site or location, and the feeds (one
  # circuit each) they supply, with what usable capacity derives from. Both
  # are entered, never discovered, and each has a resource envelope like the
  # other DCIM objects.
  def change do
    create table(:power_panels, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :organization_id, :binary_id, null: false

      add :resource_id,
          references(:resources,
            with: [organization_id: :organization_id],
            on_delete: :delete_all,
            type: :binary_id,
            name: :power_panels_organization_resource_fkey
          ),
          null: false

      add :site_id,
          references(:sites,
            with: [organization_id: :organization_id],
            on_delete: :restrict,
            type: :binary_id,
            name: :power_panels_organization_site_fkey
          ),
          null: false

      add :location_id,
          references(:locations,
            with: [organization_id: :organization_id, site_id: :site_id],
            on_delete: :restrict,
            type: :binary_id,
            name: :power_panels_site_location_fkey
          )

      add :name, :string, null: false
      add :description, :text
      add :metadata, :map, null: false, default: %{}

      timestamps(type: :"timestamp(3)")
    end

    create unique_index(:power_panels, [:organization_id, :resource_id])
    create unique_index(:power_panels, [:id, :organization_id])
    create unique_index(:power_panels, [:id, :organization_id, :site_id])
    create unique_index(:power_panels, [:organization_id, :site_id, :name])

    create table(:power_feeds, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :organization_id, :binary_id, null: false

      add :resource_id,
          references(:resources,
            with: [organization_id: :organization_id],
            on_delete: :delete_all,
            type: :binary_id,
            name: :power_feeds_organization_resource_fkey
          ),
          null: false

      # The panel's site, copied so a rack can be required to share it.
      add :site_id, :binary_id, null: false

      add :panel_id,
          references(:power_panels,
            with: [organization_id: :organization_id, site_id: :site_id],
            on_delete: :restrict,
            type: :binary_id,
            name: :power_feeds_site_panel_fkey
          ),
          null: false

      add :rack_id,
          references(:racks,
            with: [organization_id: :organization_id, site_id: :site_id],
            on_delete: {:nilify, [:rack_id]},
            type: :binary_id,
            name: :power_feeds_site_rack_fkey
          )

      add :name, :string, null: false
      add :status, :string, null: false, default: "active"
      add :supply, :string, null: false
      add :phase, :string
      add :voltage, :decimal, null: false
      add :amperage, :decimal, null: false
      add :max_utilization, :integer, null: false, default: 80
      add :side, :string
      add :description, :text
      add :metadata, :map, null: false, default: %{}

      timestamps(type: :"timestamp(3)")
    end

    create unique_index(:power_feeds, [:organization_id, :resource_id])
    create unique_index(:power_feeds, [:id, :organization_id])
    create unique_index(:power_feeds, [:organization_id, :panel_id, :name])
    create index(:power_feeds, [:organization_id, :rack_id], where: "rack_id IS NOT NULL")

    create constraint(:power_feeds, :power_feeds_electrical,
             check: """
             supply IN ('ac', 'dc')
             AND ((supply = 'ac' AND phase IS NOT NULL AND phase IN ('single', 'three'))
                  OR (supply = 'dc' AND phase IS NULL))
             AND voltage > 0
             AND amperage > 0
             AND max_utilization BETWEEN 1 AND 100
             AND (side IS NULL OR side IN ('a', 'b'))
             AND status IN ('planned', 'active', 'offline', 'decommissioning')
             """
           )
  end
end
