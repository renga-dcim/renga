defmodule Renga.Repo.Migrations.CreateResourceGroupSuggestions do
  @moduledoc """
  RFD 18 group suggestions: a `group` triage rule matches resources by
  hostname pattern or collector label, like `ownership`, but only suggests
  a resource group. A person accepts or dismisses each suggestion in the
  Inbox; until then nothing changes, so direct membership stays a trusted
  attribute.

  One suggestion row exists per resource and group. `rule_updated_at`
  remembers which version of the rule raised it, so a dismissed suggestion
  is raised again only after the rule changes.
  """

  use Ecto.Migration

  @old_shape """
  (kind = 'network_location' AND site_id IS NOT NULL AND team_id IS NULL
    AND hostname_pattern IS NULL AND label_key IS NULL AND label_value IS NULL
    AND ((subnet IS NOT NULL) <> (intake_api_key_id IS NOT NULL)))
  OR (kind = 'top_of_rack' AND site_id IS NULL AND location_id IS NULL
    AND team_id IS NULL AND subnet IS NULL AND intake_api_key_id IS NULL
    AND hostname_pattern IS NULL AND label_key IS NULL AND label_value IS NULL)
  OR (kind = 'ownership' AND team_id IS NOT NULL AND site_id IS NULL
    AND location_id IS NULL AND subnet IS NULL AND intake_api_key_id IS NULL
    AND ((hostname_pattern IS NOT NULL) <> (label_key IS NOT NULL))
    AND ((label_key IS NULL) = (label_value IS NULL)))
  """

  @new_shape """
  (kind <> 'group' AND resource_group_id IS NULL AND (#{@old_shape}))
  OR (kind = 'group' AND resource_group_id IS NOT NULL AND team_id IS NULL
    AND site_id IS NULL AND location_id IS NULL AND subnet IS NULL
    AND intake_api_key_id IS NULL
    AND ((hostname_pattern IS NOT NULL) <> (label_key IS NOT NULL))
    AND ((label_key IS NULL) = (label_value IS NULL)))
  """

  def up do
    alter table(:triage_rules) do
      add :resource_group_id,
          references(:resource_groups,
            with: [organization_id: :organization_id],
            on_delete: :delete_all,
            type: :binary_id,
            name: :triage_rules_resource_group_fkey
          )
    end

    drop constraint(:triage_rules, :triage_rules_valid_shape)
    create constraint(:triage_rules, :triage_rules_valid_shape, check: @new_shape)

    create table(:resource_group_suggestions, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :organization_id, references(:organizations, on_delete: :delete_all, type: :binary_id),
        null: false

      add :resource_id,
          references(:resources,
            with: [organization_id: :organization_id],
            on_delete: :delete_all,
            type: :binary_id,
            name: :resource_group_suggestions_tenant_resource_fkey
          ),
          null: false

      add :group_id,
          references(:resource_groups,
            with: [organization_id: :organization_id],
            on_delete: :delete_all,
            type: :binary_id,
            name: :resource_group_suggestions_tenant_group_fkey
          ),
          null: false

      add :rule_id,
          references(:triage_rules,
            with: [organization_id: :organization_id],
            on_delete: {:nilify, [:rule_id]},
            type: :binary_id,
            name: :resource_group_suggestions_tenant_rule_fkey
          )

      add :rule_name, :string, null: false
      add :rule_updated_at, :utc_datetime_usec, null: false
      add :status, :string, null: false, default: "open"
      add :decided_by_user_id, references(:users, on_delete: :nilify_all, type: :binary_id)
      add :decided_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:resource_group_suggestions, [:organization_id, :resource_id, :group_id])

    create index(:resource_group_suggestions, [:organization_id, :status])

    create constraint(:resource_group_suggestions, :resource_group_suggestions_status,
             check: "status IN ('open', 'accepted', 'dismissed')"
           )
  end

  def down do
    drop table(:resource_group_suggestions)
    execute "DELETE FROM triage_rules WHERE kind = 'group'"
    drop constraint(:triage_rules, :triage_rules_valid_shape)
    create constraint(:triage_rules, :triage_rules_valid_shape, check: @old_shape)

    alter table(:triage_rules) do
      remove :resource_group_id
    end
  end
end
