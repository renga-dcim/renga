defmodule Renga.Repo.Migrations.CreateRoleAssignments do
  use Ecto.Migration

  # RFD 17 assignments: one role, built-in or custom, given to one member in
  # addition to their base role, optionally until a deadline. Conditions and
  # other subjects (teams, claim values, SCIM groups) arrive later. The
  # composite keys keep the member and the role in the assignment's
  # organization, and deleting a custom role removes its assignments.
  def change do
    create table(:role_assignments, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :organization_id, references(:organizations, on_delete: :delete_all, type: :binary_id),
        null: false

      add :membership_id,
          references(:organization_memberships,
            with: [organization_id: :organization_id],
            on_delete: :delete_all,
            type: :binary_id,
            name: :role_assignments_tenant_membership_fkey
          ),
          null: false

      add :built_in_role, :string

      add :role_id,
          references(:roles,
            with: [organization_id: :organization_id],
            on_delete: :delete_all,
            type: :binary_id,
            name: :role_assignments_tenant_role_fkey
          )

      add :valid_until, :utc_datetime_usec
      add :expired_at, :utc_datetime_usec
      add :source, :string, null: false, default: "manual"
      add :reason, :text
      add :created_by_user_id, references(:users, type: :binary_id, on_delete: :nilify_all)

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create constraint(:role_assignments, :role_assignments_one_role,
             check: "num_nonnulls(built_in_role, role_id) = 1"
           )

    create constraint(:role_assignments, :role_assignments_built_in_role,
             check: "built_in_role IN ('owner', 'admin', 'member', 'viewer')"
           )

    create index(:role_assignments, [:organization_id, :membership_id])
    create index(:role_assignments, [:role_id])

    create index(:role_assignments, [:valid_until],
             where: "valid_until IS NOT NULL AND expired_at IS NULL"
           )
  end
end
