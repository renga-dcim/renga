defmodule Renga.Repo.Migrations.CreateOrganizationInvitations do
  use Ecto.Migration

  # RFD 17 member administration: an invitation offers one base role in one
  # organization to one email address. Only a hash of its single-use token is
  # stored; it expires, can be revoked, and is accepted at most once.
  def change do
    create table(:organization_invitations, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :organization_id, references(:organizations, type: :binary_id, on_delete: :delete_all),
        null: false

      add :email, :citext, null: false
      add :role, :string, null: false
      add :token_hash, :binary, null: false
      add :expires_at, :utc_datetime_usec, null: false

      add :invited_by_user_id, references(:users, type: :binary_id, on_delete: :nilify_all)
      add :accepted_at, :utc_datetime_usec
      add :accepted_by_user_id, references(:users, type: :binary_id, on_delete: :nilify_all)
      add :revoked_at, :utc_datetime_usec
      add :revoked_by_user_id, references(:users, type: :binary_id, on_delete: :nilify_all)

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:organization_invitations, [:token_hash])

    # One open invitation per address; inviting again replaces it.
    create unique_index(:organization_invitations, [:organization_id, :email],
             where: "accepted_at IS NULL AND revoked_at IS NULL",
             name: :organization_invitations_open_email_index
           )

    create constraint(:organization_invitations, :organization_invitations_role_check,
             check: "role IN ('owner', 'admin', 'member', 'viewer')"
           )
  end
end
