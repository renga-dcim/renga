defmodule Renga.Repo.Migrations.AddUserFkToOrganizationMemberships do
  use Ecto.Migration

  def change do
    alter table(:organization_memberships) do
      modify :user_id, references(:users, type: :binary_id, on_delete: :delete_all),
        from: :binary_id,
        null: false
    end
  end
end
