defmodule Renga.Repo.Migrations.CreateIdentityProviders do
  use Ecto.Migration

  # RFD 15 identity providers stored in the database. A provider's ID
  # permanently names its kind, issuer, and scope, so removal keeps the row as
  # a tombstone and the ID is never reused. Everything that affects
  # authentication lives in revisions, which are written once; the provider
  # points at the revision in use and at most one pending revision.
  def change do
    create table(:identity_providers, primary_key: false) do
      add :id, :string, primary_key: true
      add :kind, :string, null: false
      add :issuer, :string
      # Organization providers (RFD 15) arrive later; deployment providers
      # leave this empty.
      add :organization_id, references(:organizations, type: :binary_id, on_delete: :restrict)
      add :display_name, :string, null: false
      add :icon, :string
      add :hidden, :boolean, null: false, default: false
      add :enabled, :boolean, null: false, default: true
      add :active_revision, :integer
      add :pending_revision, :integer
      # The authoritative configuration revision: every change increments it,
      # and nodes compare it before using a cached copy.
      add :version, :bigint, null: false, default: 1
      add :removed_at, :"timestamp(3)"

      timestamps(type: :"timestamp(3)")
    end

    create constraint(:identity_providers, :kind_issuer,
             check:
               "(kind = 'oidc' AND issuer IS NOT NULL) OR (kind = 'github' AND issuer IS NULL)"
           )

    create index(:identity_providers, [:organization_id])

    create table(:identity_provider_revisions, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :provider_id, references(:identity_providers, type: :string, on_delete: :restrict),
        null: false

      add :number, :integer, null: false
      add :client_id, :string, null: false
      add :client_secret_ciphertext, :binary
      add :client_secret_key_id, :string
      add :client_secret_set_at, :"timestamp(3)"
      add :scopes, {:array, :string}, null: false, default: []
      add :email_domains, {:array, :string}, null: false, default: []
      add :allow_sign_up, :boolean, null: false, default: false
      add :session_lifetime_seconds, :integer, null: false
      add :created_by, :string, null: false

      timestamps(type: :"timestamp(3)", updated_at: false)
    end

    create unique_index(:identity_provider_revisions, [:provider_id, :number])

    create table(:identity_provider_events, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :provider_id, references(:identity_providers, type: :string, on_delete: :restrict),
        null: false

      add :kind, :string, null: false
      add :revision, :integer
      add :changed, {:array, :string}, null: false, default: []
      add :actor, :string, null: false
      add :actor_user_id, references(:users, type: :binary_id, on_delete: :nilify_all)

      timestamps(type: :"timestamp(3)", updated_at: false)
    end

    create index(:identity_provider_events, [:provider_id, :inserted_at])
  end
end
