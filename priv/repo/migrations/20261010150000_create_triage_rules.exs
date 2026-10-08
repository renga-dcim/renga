defmodule Renga.Repo.Migrations.CreateTriageRules do
  @moduledoc """
  Triage rules (RFD 8, "Triage"): a small fixed set of rule types, each
  turning one strong signal into one fact.

    * `network_location` - a reporting subnet or an intake key sets a site
      (and optionally a location);
    * `top_of_rack` - a resource whose LLDP neighbor is a switch placed in a
      rack goes in that rack, never at a rack unit;
    * `ownership` - a hostname pattern or a collector label sets the owning
      team.

  Rules only fill facts a resource lacks, so they never overwrite a fact a
  person set. Owners a rule set point back at it through `owner_rule_id`;
  placements carry the rule in their provenance.
  """

  use Ecto.Migration

  def change do
    create table(:triage_rules, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :organization_id, references(:organizations, on_delete: :delete_all, type: :binary_id),
        null: false

      add :kind, :string, null: false
      add :name, :string, null: false
      add :enabled, :boolean, null: false, default: true

      # Conditions; which apply depends on the kind.
      add :subnet, :inet

      add :intake_api_key_id,
          references(:intake_api_keys,
            with: [organization_id: :organization_id],
            on_delete: :delete_all,
            type: :binary_id,
            name: :triage_rules_intake_api_key_fkey
          )

      add :hostname_pattern, :string
      add :label_key, :string
      add :label_value, :string

      # The fact the rule sets.
      add :site_id,
          references(:sites,
            with: [organization_id: :organization_id],
            on_delete: :delete_all,
            type: :binary_id,
            name: :triage_rules_site_fkey
          )

      add :location_id,
          references(:locations,
            with: [organization_id: :organization_id],
            on_delete: :delete_all,
            type: :binary_id,
            name: :triage_rules_location_fkey
          )

      add :team_id,
          references(:teams,
            with: [organization_id: :organization_id],
            on_delete: :delete_all,
            type: :binary_id,
            name: :triage_rules_team_fkey
          )

      add :created_by_user_id, references(:users, on_delete: :nilify_all, type: :binary_id)

      timestamps(type: :utc_datetime_usec)
    end

    create index(:triage_rules, [:organization_id, :kind])
    create unique_index(:triage_rules, [:id, :organization_id])

    create unique_index(:triage_rules, [:organization_id, "lower(name)"],
             name: :triage_rules_organization_name_index
           )

    create constraint(:triage_rules, :triage_rules_valid_shape,
             check: """
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
           )

    alter table(:resources) do
      add :owner_rule_id,
          references(:triage_rules,
            with: [organization_id: :organization_id],
            on_delete: {:nilify, [:owner_rule_id]},
            type: :binary_id,
            name: :resources_owner_rule_fkey
          )
    end

    # Only a rule-set owner points at a rule; a person's choice never does.
    create constraint(:resources, :resources_owner_rule_state,
             check: "owner_rule_id IS NULL OR owner_source = 'rule'"
           )
  end
end
