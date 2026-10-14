defmodule Renga.Repo.Migrations.AddJobResource do
  use Ecto.Migration

  # RFD 9 phase 4: a job can name the resource it was requested from, so the
  # resource page can show it and its outcome lands in the resource's
  # activity. A job still targets an agent; the resource is context.
  def change do
    alter table(:jobs) do
      add :resource_id,
          references(:resources,
            with: [organization_id: :organization_id],
            on_delete: {:nilify, [:resource_id]},
            type: :binary_id,
            name: :jobs_tenant_resource_fkey
          )
    end

    create index(:jobs, [:organization_id, :resource_id, :inserted_at],
             where: "resource_id IS NOT NULL",
             name: :jobs_resource_index
           )
  end
end
