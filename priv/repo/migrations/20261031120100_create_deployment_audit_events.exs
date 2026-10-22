defmodule Renga.Repo.Migrations.CreateDeploymentAuditEvents do
  use Ecto.Migration

  # RFD 22, "Audit": every attempted operator mutation, from a release command
  # or the operator API, with who made it and what it changed, but never a
  # request body, credential, or secret. Targets are kept as plain IDs and
  # name snapshots, without foreign keys, so the record outlives what it names.
  def change do
    create table(:deployment_audit_events) do
      add :operation, :string, null: false
      add :outcome, :string, null: false
      add :actor, :string, null: false
      add :actor_token_id, :binary_id
      add :invocation_id, :string, null: false
      add :target_id, :string
      add :organization_id, :binary_id
      add :organization_name, :string
      add :changed, {:array, :string}, null: false, default: []
      add :reason, :string

      timestamps(type: :"timestamp(3)", updated_at: false)
    end

    create index(:deployment_audit_events, [:inserted_at])
    create index(:deployment_audit_events, [:organization_id, :inserted_at])
  end
end
