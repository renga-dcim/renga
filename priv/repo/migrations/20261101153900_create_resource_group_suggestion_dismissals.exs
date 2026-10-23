defmodule Renga.Repo.Migrations.CreateResourceGroupSuggestionDismissals do
  @moduledoc """
  A resource/group has one suggestion, but multiple rules may independently
  suggest it. Remember each dismissed rule version so unchanged overlapping
  rules cannot repeatedly reopen one another's dismissed suggestion.
  """

  use Ecto.Migration

  def change do
    create unique_index(:resource_group_suggestions, [:id, :organization_id])

    create table(:resource_group_suggestion_dismissals, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :organization_id, references(:organizations, on_delete: :delete_all, type: :binary_id),
        null: false

      add :suggestion_id,
          references(:resource_group_suggestions,
            with: [organization_id: :organization_id],
            on_delete: :delete_all,
            type: :binary_id,
            name: :resource_group_suggestion_dismissals_tenant_suggestion_fkey
          ),
          null: false

      add :rule_id,
          references(:triage_rules,
            with: [organization_id: :organization_id],
            on_delete: :delete_all,
            type: :binary_id,
            name: :resource_group_suggestion_dismissals_tenant_rule_fkey
          ),
          null: false

      add :rule_updated_at, :utc_datetime_usec, null: false

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:resource_group_suggestion_dismissals, [:suggestion_id, :rule_id])
    create index(:resource_group_suggestion_dismissals, [:organization_id, :rule_id])
  end
end
