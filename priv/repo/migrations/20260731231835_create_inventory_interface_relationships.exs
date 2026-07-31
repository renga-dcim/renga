defmodule Renga.Repo.Migrations.CreateInventoryInterfaceRelationships do
  use Ecto.Migration

  def change do
    create table(:interface_relationships, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :organization_id, references(:organizations, on_delete: :delete_all, type: :binary_id),
        null: false

      add :source_interface_id, references(:interfaces, on_delete: :delete_all, type: :binary_id),
        null: false

      add :target_interface_id, references(:interfaces, on_delete: :delete_all, type: :binary_id),
        null: false

      add :source_id, references(:sources, on_delete: :nilify_all, type: :binary_id)
      add :kind, :string, null: false
      add :metadata, :map, null: false, default: %{}
      add :first_seen_at, :utc_datetime
      add :last_seen_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    create index(:interface_relationships, [:organization_id, :source_interface_id],
             name: :interface_relationships_org_source_interface_index
           )

    create index(:interface_relationships, [:organization_id, :target_interface_id],
             name: :interface_relationships_org_target_interface_index
           )

    create index(:interface_relationships, [:organization_id, :source_id])
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
  end
end
