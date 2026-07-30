defmodule Renga.Repo.Migrations.CreateInventorySources do
  use Ecto.Migration

  def change do
    create table(:sources, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :organization_id, references(:organizations, on_delete: :delete_all, type: :binary_id),
        null: false

      add :kind, :string, null: false
      add :name, :string, null: false
      add :status, :string, null: false, default: "active"
      add :token_hash, :binary
      add :capabilities, {:array, :string}, null: false, default: []
      add :last_seen_at, :utc_datetime
      add :metadata, :map, null: false, default: %{}

      timestamps(type: :utc_datetime)
    end

    create unique_index(:sources, [:organization_id, :name])
    create index(:sources, [:organization_id, :kind])
    create index(:sources, [:organization_id, :status])
    create index(:sources, [:organization_id, :last_seen_at])
  end
end
