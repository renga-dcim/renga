defmodule Renga.Repo.Migrations.ScopeSessionsToAnOrganization do
  use Ecto.Migration

  # RFD 15: a session that signed in through an organization's identity
  # provider can open only that organization. Removing the organization
  # ends its scoped sessions.
  def change do
    alter table(:users_tokens) do
      add :scoped_organization_id,
          references(:organizations, type: :binary_id, on_delete: :delete_all)
    end

    create index(:users_tokens, [:scoped_organization_id],
             where: "scoped_organization_id IS NOT NULL"
           )
  end
end
