defmodule Renga.Repo.Migrations.CreateRoles do
  use Ecto.Migration

  # RFD 17 custom roles: a named set of permissions an organization defines.
  # The built-in roles live in code (Renga.Authorization) and are never rows.
  # Permission names are validated against the code catalogue, not the
  # database, so a release can add permissions without a migration.
  def change do
    create table(:roles, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :organization_id, references(:organizations, on_delete: :delete_all, type: :binary_id),
        null: false

      add :name, :string, null: false
      add :description, :text
      add :permissions, {:array, :string}, null: false, default: []

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:roles, [:organization_id, "lower(name)"],
             name: :roles_organization_name_index
           )

    create unique_index(:roles, [:id, :organization_id])
  end
end
