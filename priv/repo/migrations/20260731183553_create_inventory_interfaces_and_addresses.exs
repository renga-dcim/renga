defmodule Renga.Repo.Migrations.CreateInventoryInterfacesAndAddresses do
  use Ecto.Migration

  def change do
    create table(:interfaces, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :organization_id, references(:organizations, on_delete: :delete_all, type: :binary_id),
        null: false

      add :resource_id, references(:resources, on_delete: :delete_all, type: :binary_id),
        null: false

      add :source_id, references(:sources, on_delete: :nilify_all, type: :binary_id)
      add :name, :string, null: false
      add :mac_address, :string
      add :kind, :string, null: false, default: "ethernet"
      add :status, :string, null: false, default: "unknown"
      add :mtu, :integer
      add :speed_mbps, :integer
      add :metadata, :map, null: false, default: %{}
      add :first_seen_at, :utc_datetime
      add :last_seen_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    create index(:interfaces, [:organization_id, :resource_id])
    create index(:interfaces, [:organization_id, :source_id])
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

      add :source_id, references(:sources, on_delete: :nilify_all, type: :binary_id)
      add :kind, :string, null: false
      add :address, :string, null: false
      add :prefix_length, :integer
      add :scope, :string
      add :metadata, :map, null: false, default: %{}
      add :first_seen_at, :utc_datetime
      add :last_seen_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    create index(:addresses, [:organization_id, :resource_id])
    create index(:addresses, [:organization_id, :interface_id])
    create index(:addresses, [:organization_id, :source_id])

    create unique_index(:addresses, [:organization_id, :interface_id, :address, :prefix_length],
             name: :addresses_organization_id_interface_id_address_prefix_length_in
           )
  end
end
