defmodule Renga.Repo.Migrations.CreateScimConnections do
  use Ecto.Migration

  # RFD 16: an organization's SCIM connection to its identity provider, and
  # the bearer tokens that provider sends. Only a hash of each token is kept.
  # The provider and correlation claim never change in place; a replacement
  # is a new connection, so an organization keeps its disabled ones as
  # history and has at most one enabled.
  def change do
    create table(:scim_connections, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :organization_id, references(:organizations, on_delete: :delete_all, type: :binary_id),
        null: false

      add :provider_id, references(:identity_providers, type: :string, on_delete: :restrict),
        null: false

      add :correlation_claim, :string, null: false
      add :default_role, :string
      add :disabled_at, :utc_datetime_usec
      add :created_by_user_id, references(:users, type: :binary_id, on_delete: :nilify_all)

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:scim_connections, [:organization_id],
             where: "disabled_at IS NULL",
             name: :scim_connections_one_enabled
           )

    create unique_index(:scim_connections, [:organization_id, :id])
    create index(:scim_connections, [:provider_id])

    create constraint(:scim_connections, :scim_connections_default_role,
             check: "default_role IN ('owner', 'admin', 'member', 'viewer')"
           )

    create table(:scim_tokens, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :organization_id, :binary_id, null: false

      add :connection_id,
          references(:scim_connections,
            with: [organization_id: :organization_id],
            on_delete: :delete_all,
            type: :binary_id,
            name: :scim_tokens_tenant_connection_fkey
          ),
          null: false

      add :name, :string, null: false
      add :token_hash, :binary, null: false
      add :last_used_at, :utc_datetime_usec
      add :revoked_at, :utc_datetime_usec
      add :created_by_user_id, references(:users, type: :binary_id, on_delete: :nilify_all)
      add :revoked_by_user_id, references(:users, type: :binary_id, on_delete: :nilify_all)

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create unique_index(:scim_tokens, [:token_hash])
    create index(:scim_tokens, [:connection_id], where: "revoked_at IS NULL")
  end
end
