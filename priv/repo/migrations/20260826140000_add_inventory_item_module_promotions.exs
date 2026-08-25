defmodule Renga.Repo.Migrations.AddInventoryItemModulePromotions do
  use Ecto.Migration

  def up do
    alter table(:inventory_items) do
      add :promoted_module_id, :binary_id
    end

    execute """
    ALTER TABLE inventory_items
    ADD CONSTRAINT inventory_items_promoted_module_fkey
    FOREIGN KEY (promoted_module_id, organization_id)
    REFERENCES modules(id, organization_id)
    DEFERRABLE INITIALLY DEFERRED
    """

    create unique_index(:inventory_items, [:organization_id, :promoted_module_id],
             where: "promoted_module_id IS NOT NULL",
             name: :inventory_items_promoted_module_index
           )
  end

  def down do
    drop index(:inventory_items, [:organization_id, :promoted_module_id],
           name: :inventory_items_promoted_module_index
         )

    alter table(:inventory_items) do
      remove :promoted_module_id
    end
  end
end
