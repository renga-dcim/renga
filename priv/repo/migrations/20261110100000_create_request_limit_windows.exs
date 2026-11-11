defmodule Renga.Repo.Migrations.CreateRequestLimitWindows do
  use Ecto.Migration

  def change do
    create table(:request_limit_windows, primary_key: false) do
      add :organization_id, references(:organizations, type: :binary_id, on_delete: :delete_all)

      add :key, :text, primary_key: true
      add :kind, :text, null: false
      add :user_id, references(:users, type: :binary_id, on_delete: :delete_all)
      add :window, :bigint, null: false
      add :count, :bigint, null: false
    end

    create index(:request_limit_windows, [:organization_id])
  end
end
