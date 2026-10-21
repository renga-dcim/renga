defmodule Renga.Repo.Migrations.CreateUserMfa do
  use Ecto.Migration

  # RFD 19 credentials: one authenticator app (TOTP) per account, ten
  # single-use recovery codes stored hashed, and the per-account security
  # events that rate limiting and the security log read.
  def change do
    create table(:user_totps, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :user_id, references(:users, type: :binary_id, on_delete: :delete_all), null: false
      add :secret, :binary, null: false
      # The last accepted 30-second step, so a code is never accepted twice.
      add :last_used_step, :bigint

      timestamps(type: :"timestamp(3)")
    end

    create unique_index(:user_totps, [:user_id])

    create table(:user_recovery_codes, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :user_id, references(:users, type: :binary_id, on_delete: :delete_all), null: false
      add :code_hash, :binary, null: false
      add :used_at, :"timestamp(3)"

      timestamps(type: :"timestamp(3)", updated_at: false)
    end

    create index(:user_recovery_codes, [:user_id])

    create table(:account_security_events, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :user_id, references(:users, type: :binary_id, on_delete: :delete_all), null: false
      add :kind, :string, null: false
      add :metadata, :map, null: false, default: %{}

      timestamps(type: :"timestamp(3)", updated_at: false)
    end

    create index(:account_security_events, [:user_id, :kind, :inserted_at])
  end
end
