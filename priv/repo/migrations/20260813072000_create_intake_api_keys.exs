defmodule Renga.Repo.Migrations.CreateIntakeApiKeys do
  use Ecto.Migration

  def change do
    create table(:intake_api_keys, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :organization_id,
          references(:organizations, on_delete: :delete_all, type: :binary_id),
          null: false

      add :name, :string, null: false
      add :token_hash, :binary, null: false
      add :status, :string, null: false, default: "active"

      timestamps(type: :"timestamp(3)")
    end

    create unique_index(:intake_api_keys, [:token_hash])
    create index(:intake_api_keys, [:organization_id, :status])

    create constraint(:intake_api_keys, :intake_api_keys_status,
             check: "status IN ('active', 'revoked')"
           )
  end
end
