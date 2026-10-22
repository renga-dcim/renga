defmodule Renga.Repo.Migrations.AddImportedPrincipalToInvitations do
  use Ecto.Migration

  # RFD 20: an invitation that links an imported principal to whoever
  # accepts it, restoring the principal's held access.
  def change do
    alter table(:organization_invitations) do
      add :imported_principal_id,
          references(:imported_principals,
            with: [organization_id: :organization_id],
            on_delete: :delete_all
          )
    end

    create index(:organization_invitations, [:imported_principal_id])
  end
end
