defmodule Renga.Repo.Migrations.CreateScimUsers do
  use Ecto.Migration

  # RFD 16 directory entries: a user a SCIM connection's provider assigned
  # to the organization. An entry is not a Renga account; it reaches one only
  # through the RFD 15 identity that proved its correlation claim, which a
  # later change links.
  def change do
    create table(:scim_users, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :organization_id, :binary_id, null: false

      add :connection_id,
          references(:scim_connections,
            with: [organization_id: :organization_id],
            on_delete: :delete_all,
            type: :binary_id,
            name: :scim_users_tenant_connection_fkey
          ),
          null: false

      add :user_name, :citext, null: false
      add :external_id, :string
      add :display_name, :string
      add :formatted_name, :string
      add :given_name, :string
      add :family_name, :string
      add :email, :string
      add :active, :boolean, null: false, default: true

      add :user_identity_id,
          references(:user_identities, type: :binary_id, on_delete: :nilify_all)

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:scim_users, [:connection_id, :user_name])

    create unique_index(:scim_users, [:connection_id, :external_id],
             where: "external_id IS NOT NULL"
           )

    create unique_index(:scim_users, [:organization_id, :id])
    create index(:scim_users, [:user_identity_id])
  end
end
