defmodule Renga.Repo.Migrations.CreateInventoryItems do
  use Ecto.Migration

  def up do
    create table(:inventory_items, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :organization_id, :binary_id, null: false

      add :owner_resource_id,
          references(:resources,
            with: [organization_id: :organization_id],
            on_delete: :delete_all,
            type: :binary_id,
            name: :inventory_items_owner_resource_fkey
          ),
          null: false

      add :parent_id, :binary_id
      add :name, :string, null: false
      add :kind, :string, null: false
      add :status, :string, null: false, default: "unknown"
      add :position, :string
      add :serial_number, :string
      add :part_number, :string
      add :asset_tag, :string
      add :metadata, :map, null: false, default: %{}
      timestamps(type: :"timestamp(3)")
    end

    create unique_index(:inventory_items, [:id, :organization_id, :owner_resource_id])

    alter table(:inventory_items) do
      modify :parent_id,
             references(:inventory_items,
               with: [organization_id: :organization_id, owner_resource_id: :owner_resource_id],
               on_delete: :restrict,
               type: :binary_id,
               name: :inventory_items_owner_parent_fkey
             )
    end

    create constraint(:inventory_items, :inventory_items_not_self_parent,
             check: "parent_id IS NULL OR parent_id <> id"
           )

    create unique_index(:inventory_items, [:organization_id, :owner_resource_id, "lower(name)"],
             name: :inventory_items_owner_name_index
           )

    create index(:inventory_items, [:organization_id, :owner_resource_id, :parent_id],
             name: :inventory_items_owner_parent_index
           )

    create index(:inventory_items, [:organization_id, :serial_number])
  end

  def down do
    drop table(:inventory_items)
  end
end
