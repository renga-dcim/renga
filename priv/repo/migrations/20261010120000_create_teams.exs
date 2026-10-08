defmodule Renga.Repo.Migrations.CreateTeams do
  @moduledoc """
  Teams and resource ownership (RFD 8, "Triage": a resource needs an owner).

  A team is an organization's name for a group that answers for resources.
  Each resource has at most one owning team. How the owner was set is kept
  beside it (`owner_source`), so triage rules can later fill owners without
  ever replacing one a person chose.
  """

  use Ecto.Migration

  def change do
    create table(:teams, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :organization_id, references(:organizations, on_delete: :delete_all, type: :binary_id),
        null: false

      add :name, :string, null: false
      add :description, :text

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:teams, [:organization_id, "lower(name)"],
             name: :teams_organization_name_index
           )

    create unique_index(:teams, [:id, :organization_id])

    alter table(:resources) do
      add :owner_team_id,
          references(:teams,
            with: [organization_id: :organization_id],
            # Deleting a team clears only the owner, never the organization.
            on_delete: {:nilify, [:owner_team_id]},
            type: :binary_id,
            name: :resources_owner_team_fkey
          )

      add :owner_source, :string
      add :owner_set_at, :utc_datetime_usec
    end

    create index(:resources, [:organization_id, :owner_team_id])

    create constraint(:resources, :resources_owner_source_state,
             check: """
             (owner_team_id IS NULL AND owner_source IS NULL) OR
               (owner_team_id IS NOT NULL AND owner_source IN ('person', 'rule'))
             """
           )
  end
end
