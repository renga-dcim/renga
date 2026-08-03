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
      add :metadata, :map, null: false, default: %{}

      timestamps(type: :"timestamp(3)")
    end

    create unique_index(:sources, [:organization_id, :name])
    create index(:sources, [:organization_id, :kind])
    create index(:sources, [:organization_id, :status])

    create table(:agents, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :organization_id, references(:organizations, on_delete: :delete_all, type: :binary_id),
        null: false

      add :source_id, references(:sources, on_delete: :restrict, type: :binary_id), null: false
      add :name, :string, null: false
      add :status, :string, null: false, default: "active"
      add :version, :string
      add :capabilities, {:array, :string}, null: false, default: []
      add :metadata, :map, null: false, default: %{}
      add :registered_at, :"timestamp(3)", null: false

      timestamps(type: :"timestamp(3)")
    end

    create unique_index(:agents, [:organization_id, :source_id, :name])
    create index(:agents, [:organization_id, :status])

    create table(:agent_leases, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :organization_id, references(:organizations, on_delete: :delete_all, type: :binary_id),
        null: false

      add :agent_id, references(:agents, on_delete: :delete_all, type: :binary_id), null: false
      add :renewed_at, :"timestamp(3)", null: false
      add :expires_at, :"timestamp(3)", null: false

      timestamps(type: :"timestamp(3)")
    end

    create unique_index(:agent_leases, [:organization_id, :agent_id])
    create index(:agent_leases, [:organization_id, :expires_at])
  end
end
