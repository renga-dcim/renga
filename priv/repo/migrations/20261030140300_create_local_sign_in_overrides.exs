defmodule Renga.Repo.Migrations.CreateLocalSignInOverrides do
  use Ecto.Migration

  # RFD 15 local recovery override: a time-limited exception, created only by
  # the operator's release command, that lets existing local credentials
  # sign in while the environment disables them.
  def change do
    create table(:local_sign_in_overrides, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :expires_at, :"timestamp(3)", null: false
      add :created_by, :string, null: false
      add :revoked_at, :"timestamp(3)"
      add :revoked_by, :string

      timestamps(type: :"timestamp(3)", updated_at: false)
    end

    create index(:local_sign_in_overrides, [:expires_at])
  end
end
