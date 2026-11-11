defmodule Renga.Repo.Migrations.QueueExportGeneration do
  use Ecto.Migration

  def change do
    alter table(:organization_exports) do
      add :notification_url, :text
      add :processing_deadline, :utc_datetime_usec
    end

    create index(:organization_exports, [:organization_id, :processing_deadline],
             where: "status = 'running'",
             name: :organization_exports_generation_queue
           )
  end
end
