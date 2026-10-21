defmodule Renga.Repo.Migrations.CreateIdentityProviderTests do
  use Ecto.Migration

  # RFD 15 test sign-ins: one row per test of a pending revision, bound to
  # the person or operator who asked for it. The start link and the callback
  # state are stored hashed, and each works once.
  def change do
    create table(:identity_provider_tests, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :provider_id, references(:identity_providers, type: :string, on_delete: :restrict),
        null: false

      add :revision, :integer, null: false
      add :token_hash, :binary, null: false
      add :state_hash, :binary
      add :nonce, :string
      add :verifier, :string
      add :actor, :string, null: false
      add :actor_user_id, references(:users, type: :binary_id, on_delete: :delete_all)
      add :expires_at, :"timestamp(3)", null: false
      add :started_at, :"timestamp(3)"
      add :completed_at, :"timestamp(3)"

      timestamps(type: :"timestamp(3)", updated_at: false)
    end

    create unique_index(:identity_provider_tests, [:token_hash])
    create unique_index(:identity_provider_tests, [:state_hash])
    create index(:identity_provider_tests, [:provider_id])
  end
end
