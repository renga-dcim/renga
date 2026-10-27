defmodule Renga.Repo.Migrations.FenceOrganizationStatusUpdates do
  use Ecto.Migration

  def change do
    # This non-partial, non-deferrable unique key is a concurrency boundary,
    # not just a redundant lookup index. PostgreSQL treats status changes as
    # key updates, so intake's KEY SHARE fence blocks even a direct UPDATE
    # status, while canonical NO KEY UPDATE work can run beside check-ins.
    create unique_index(:organizations, [:id, :status], name: :organizations_status_lock_key)
  end
end
