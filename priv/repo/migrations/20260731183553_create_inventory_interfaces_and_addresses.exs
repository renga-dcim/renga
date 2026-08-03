defmodule Renga.Repo.Migrations.CreateInventoryInterfacesAndAddresses do
  use Ecto.Migration

  def change do
    create table(:interfaces, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :organization_id, references(:organizations, on_delete: :delete_all, type: :binary_id),
        null: false

      add :resource_id, references(:resources, on_delete: :delete_all, type: :binary_id),
        null: false

      add :name, :string, null: false
      add :mac_address, :macaddr
      add :kind, :string, null: false, default: "ethernet"
      add :status, :string, null: false, default: "unknown"
      add :mtu, :integer
      add :speed_mbps, :integer
      add :metadata, :map, null: false, default: %{}
      timestamps(type: :"timestamp(3)")
    end

    create index(:interfaces, [:organization_id, :resource_id])
    create index(:interfaces, [:organization_id, :mac_address])
    create unique_index(:interfaces, [:organization_id, :resource_id, :name])

    create table(:addresses, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :organization_id, references(:organizations, on_delete: :delete_all, type: :binary_id),
        null: false

      add :resource_id, references(:resources, on_delete: :delete_all, type: :binary_id),
        null: false

      add :interface_id, references(:interfaces, on_delete: :delete_all, type: :binary_id),
        null: false

      add :kind, :string, null: false
      add :address, :inet, null: false
      add :scope, :string
      add :metadata, :map, null: false, default: %{}
      timestamps(type: :"timestamp(3)")
    end

    create index(:addresses, [:organization_id, :resource_id])
    create index(:addresses, [:organization_id, :interface_id])
    create unique_index(:addresses, [:organization_id, :interface_id, :address])

    create table(:prefixes, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :organization_id, references(:organizations, on_delete: :delete_all, type: :binary_id),
        null: false

      add :resource_id, references(:resources, on_delete: :delete_all, type: :binary_id),
        null: false

      add :prefix, :cidr, null: false
      add :vrf, :string
      add :status, :string, null: false, default: "active"
      add :description, :text
      add :metadata, :map, null: false, default: %{}

      timestamps(type: :"timestamp(3)")
    end

    create unique_index(:prefixes, [:organization_id, :resource_id])

    execute "CREATE INDEX prefixes_prefix_gist_index ON prefixes USING gist (prefix inet_ops)",
            "DROP INDEX prefixes_prefix_gist_index"
  end
end
