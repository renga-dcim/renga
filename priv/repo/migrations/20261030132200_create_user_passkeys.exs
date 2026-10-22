defmodule Renga.Repo.Migrations.CreateUserPasskeys do
  use Ecto.Migration

  # RFD 19 passkeys: any number of WebAuthn credentials per account, and the
  # single-use challenges their ceremonies sign.
  def change do
    create table(:user_passkeys, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :user_id, references(:users, type: :binary_id, on_delete: :delete_all), null: false
      add :credential_id, :binary, null: false
      add :public_key, :binary, null: false
      add :sign_count, :bigint, null: false, default: 0
      add :transports, {:array, :string}, null: false, default: []
      add :backup_eligible, :boolean, null: false, default: false
      add :backed_up, :boolean, null: false, default: false
      add :name, :string, null: false
      add :last_used_at, :"timestamp(3)"

      timestamps(type: :"timestamp(3)")
    end

    create unique_index(:user_passkeys, [:credential_id])
    create index(:user_passkeys, [:user_id])

    create table(:webauthn_challenges, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :bytes, :binary, null: false
      add :purpose, :string, null: false
      add :user_id, references(:users, type: :binary_id, on_delete: :delete_all)
      add :expires_at, :"timestamp(3)", null: false

      timestamps(type: :"timestamp(3)", updated_at: false)
    end

    create unique_index(:webauthn_challenges, [:bytes])
    create index(:webauthn_challenges, [:expires_at])
  end
end
