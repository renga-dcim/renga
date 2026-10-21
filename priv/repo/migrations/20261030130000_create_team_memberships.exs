defmodule Renga.Repo.Migrations.CreateTeamMemberships do
  use Ecto.Migration

  # RFD 17: teams gain members, so an assignment can say "people on a team
  # may operate what their team owns". Both sides must belong to the same
  # organization; the composite keys make the database enforce it.
  def change do
    create unique_index(:organization_memberships, [:id, :organization_id])

    create table(:team_memberships, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :organization_id, references(:organizations, on_delete: :delete_all, type: :binary_id),
        null: false

      add :team_id,
          references(:teams,
            with: [organization_id: :organization_id],
            on_delete: :delete_all,
            type: :binary_id,
            name: :team_memberships_tenant_team_fkey
          ),
          null: false

      add :membership_id,
          references(:organization_memberships,
            with: [organization_id: :organization_id],
            on_delete: :delete_all,
            type: :binary_id,
            name: :team_memberships_tenant_membership_fkey
          ),
          null: false

      add :added_by_user_id, references(:users, type: :binary_id, on_delete: :nilify_all)

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create unique_index(:team_memberships, [:team_id, :membership_id])
    create index(:team_memberships, [:organization_id, :membership_id])
  end
end
