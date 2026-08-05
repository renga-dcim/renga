defmodule Renga.Repo.Migrations.CreateInventoryResourceOverrides do
  use Ecto.Migration

  def change do
    create table(:resource_overrides, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :organization_id, references(:organizations, on_delete: :delete_all, type: :binary_id),
        null: false

      add :resource_id,
          references(:resources,
            with: [organization_id: :organization_id],
            on_delete: :delete_all,
            type: :binary_id,
            name: :resource_overrides_organization_resource_fkey
          ),
          null: false

      add :field, :string, null: false
      add :value, :map, null: false
      add :reason, :string
      add :created_by_user_id, references(:users, on_delete: :nilify_all, type: :binary_id)

      timestamps(type: :"timestamp(3)")
    end

    create index(:resource_overrides, [:organization_id, :resource_id])
    create index(:resource_overrides, [:organization_id, :created_by_user_id])
    create unique_index(:resource_overrides, [:organization_id, :resource_id, :field])
  end
end
