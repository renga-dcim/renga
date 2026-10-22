defmodule Renga.Repo.Migrations.CreateScimGroups do
  use Ecto.Migration

  # RFD 16 directory groups and their members. A group is identified by its
  # Renga-assigned id, which role mappings will name, so renaming a group
  # keeps its mapping and a recreated group starts without one. Members are
  # entries of the same connection.
  def change do
    create table(:scim_groups, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :organization_id, :binary_id, null: false

      add :connection_id,
          references(:scim_connections,
            with: [organization_id: :organization_id],
            on_delete: :delete_all,
            type: :binary_id,
            name: :scim_groups_tenant_connection_fkey
          ),
          null: false

      add :display_name, :string, null: false
      add :external_id, :string

      timestamps(type: :utc_datetime_usec)
    end

    create index(:scim_groups, [:connection_id, :display_name])
    create unique_index(:scim_groups, [:connection_id, :id])

    create unique_index(:scim_users, [:connection_id, :id])

    create table(:scim_group_members, primary_key: false) do
      add :connection_id, :binary_id, null: false

      add :group_id,
          references(:scim_groups,
            with: [connection_id: :connection_id],
            on_delete: :delete_all,
            type: :binary_id,
            name: :scim_group_members_group_fkey
          ),
          primary_key: true

      add :user_id,
          references(:scim_users,
            with: [connection_id: :connection_id],
            on_delete: :delete_all,
            type: :binary_id,
            name: :scim_group_members_user_fkey
          ),
          primary_key: true
    end

    create index(:scim_group_members, [:user_id])
  end
end
