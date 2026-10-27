defmodule Renga.Repo.Migrations.AddOrganizationLifecycle do
  use Ecto.Migration

  def change do
    alter table(:deployment_audit_events) do
      # Attribution survives account and tenant deletion; this is not a foreign key.
      add :actor_user_id, :binary_id
    end

    alter table(:organizations) do
      add :deletion_scheduled_at, :utc_datetime_usec
      add :deletion_due_at, :utc_datetime_usec
    end

    create constraint(:organizations, :organization_deletion_deadline,
             check:
               "(status IN ('deletion_pending', 'purging')) = (deletion_due_at IS NOT NULL AND deletion_scheduled_at IS NOT NULL)"
           )

    create table(:organization_lifecycle_notices, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :organization_id, references(:organizations, type: :binary_id, on_delete: :delete_all),
        null: false

      add :recipient, :string, null: false
      add :organization_name, :string, null: false
      add :operation, :string, null: false
      add :deadline, :utc_datetime_usec
      add :delivered_at, :utc_datetime_usec
    end
  end
end
