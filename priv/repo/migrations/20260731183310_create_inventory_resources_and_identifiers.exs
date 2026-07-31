defmodule Renga.Repo.Migrations.CreateInventoryResourcesAndIdentifiers do
  use Ecto.Migration

  def change do
    create table(:resources, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :organization_id, references(:organizations, on_delete: :delete_all, type: :binary_id),
        null: false

      add :kind, :string, null: false
      add :external_id, :string
      add :serial_number, :string
      add :asset_tag, :string
      add :hostname, :string
      add :fqdn, :string
      add :vendor, :string
      add :model, :string
      add :status, :string, null: false, default: "unknown"
      add :metadata, :map, null: false, default: %{}
      add :first_seen_at, :utc_datetime
      add :last_seen_at, :utc_datetime
      add :last_changed_at, :utc_datetime
      add :stale_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    create index(:resources, [:organization_id, :kind])
    create index(:resources, [:organization_id, :status])
    create index(:resources, [:organization_id, :hostname])
    create index(:resources, [:organization_id, :fqdn])
    create index(:resources, [:organization_id, :last_seen_at])

    create unique_index(:resources, [:organization_id, :external_id],
             where: "external_id IS NOT NULL"
           )

    create unique_index(:resources, [:organization_id, :serial_number],
             where: "serial_number IS NOT NULL"
           )

    create unique_index(:resources, [:organization_id, :asset_tag],
             where: "asset_tag IS NOT NULL"
           )

    create table(:resource_identifiers, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :organization_id, references(:organizations, on_delete: :delete_all, type: :binary_id),
        null: false

      add :resource_id, references(:resources, on_delete: :delete_all, type: :binary_id),
        null: false

      add :source_id, references(:sources, on_delete: :nilify_all, type: :binary_id)
      add :kind, :string, null: false
      add :value, :string, null: false
      add :confidence, :integer, null: false, default: 100
      add :first_seen_at, :utc_datetime
      add :last_seen_at, :utc_datetime
      add :metadata, :map, null: false, default: %{}

      timestamps(type: :utc_datetime)
    end

    create index(:resource_identifiers, [:organization_id, :resource_id])
    create index(:resource_identifiers, [:organization_id, :source_id])
    create index(:resource_identifiers, [:organization_id, :kind, :value])

    create unique_index(:resource_identifiers, [:organization_id, :source_id, :kind, :value],
             where: "source_id IS NOT NULL"
           )

    create unique_index(:resource_identifiers, [:organization_id, :resource_id, :kind, :value],
             name: :resource_identifiers_resource_kind_value_index
           )
  end
end
