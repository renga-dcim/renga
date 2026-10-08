defmodule Renga.Repo.Migrations.CreateFindingWorkflows do
  @moduledoc """
  Finding workflow state (RFD 8, "Inbox"): the judgment people add on top of
  findings that reconciliation opens and closes.

  One row per finding identity, not per finding row. Every finding domain
  inserts a new row when a resolved finding recurs, so state keyed by row id
  would be lost on recurrence; the identity (domain, subject, kind,
  resolution key) is what stays stable. The subject is the resource, or the
  interface for topology findings. `resource_id` is always the owning
  resource so the state disappears with it.

  Change events gain the human actor and the workflow they belong to, so
  Activity can say who assigned, snoozed, or accepted a finding.
  """

  use Ecto.Migration

  def change do
    create table(:finding_workflows, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :organization_id, :binary_id, null: false

      add :resource_id,
          references(:resources,
            with: [organization_id: :organization_id],
            on_delete: :delete_all,
            type: :binary_id,
            name: :finding_workflows_resource_fkey
          ),
          null: false

      add :domain, :string, null: false
      add :subject_id, :binary_id, null: false
      add :kind, :string, null: false
      add :resolution_key, :string, null: false, default: ""

      add :assignee_user_id, references(:users, on_delete: :nilify_all, type: :binary_id)
      add :snoozed_until, :utc_datetime_usec
      add :exception_reason, :text
      add :exception_expires_at, :utc_datetime_usec
      add :exception_at, :utc_datetime_usec
      add :exception_by_user_id, references(:users, on_delete: :nilify_all, type: :binary_id)

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(
             :finding_workflows,
             [:organization_id, :domain, :subject_id, :kind, :resolution_key],
             name: :finding_workflows_identity_index
           )

    create index(:finding_workflows, [:organization_id, :assignee_user_id])
    create index(:finding_workflows, [:organization_id, :resource_id])

    create constraint(:finding_workflows, :finding_workflows_valid_domain,
             check: "domain IN ('component', 'hardware_match', 'placement', 'topology')"
           )

    create constraint(:finding_workflows, :finding_workflows_exception_state,
             check: """
             (exception_reason IS NULL AND exception_at IS NULL AND exception_expires_at IS NULL)
               OR (exception_reason IS NOT NULL AND exception_at IS NOT NULL)
             """
           )

    alter table(:change_events) do
      add :actor_user_id, references(:users, on_delete: :nilify_all, type: :binary_id)

      add :finding_workflow_id,
          references(:finding_workflows, on_delete: :nilify_all, type: :binary_id)
    end

    create index(:change_events, [:finding_workflow_id])
  end
end
