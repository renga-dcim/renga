defmodule Renga.Repo.Migrations.RestoreAgentSourceUniqueIndex do
  use Ecto.Migration

  def change do
    drop_if_exists unique_index(:agents, [:organization_id, :source_id, :name])
    create_if_not_exists unique_index(:agents, [:organization_id, :source_id])
  end
end
