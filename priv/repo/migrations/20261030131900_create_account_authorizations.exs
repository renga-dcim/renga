defmodule Renga.Repo.Migrations.CreateAccountAuthorizations do
  use Ecto.Migration

  # RFD 19 replaces sudo mode with a narrow, in-place account re-check. Its
  # evidence lives beside, not on, the session token: issuing or rotating a
  # session must never refresh it (RFD 15, "Sign-in flow"). Each row is bound
  # to one browser session and dies with it.
  def change do
    create table(:account_authorizations, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :user_id, references(:users, type: :binary_id, on_delete: :delete_all), null: false

      add :session_token_id,
          references(:users_tokens, type: :binary_id, on_delete: :delete_all),
          null: false

      add :purpose, :string, null: false
      add :expires_at, :"timestamp(3)", null: false

      timestamps(type: :"timestamp(3)", updated_at: false)
    end

    create unique_index(:account_authorizations, [:session_token_id, :purpose])
    create index(:account_authorizations, [:user_id])

    create constraint(:account_authorizations, :account_authorizations_valid_purpose,
             check: "purpose IN ('recheck', 'bootstrap')"
           )

    # Emailed codes that prove mailbox control for RFD 19's first-password or
    # first-factor bootstrap. Codes are stored hashed and bound to the session
    # that asked for them.
    create table(:account_challenges, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :user_id, references(:users, type: :binary_id, on_delete: :delete_all), null: false

      add :session_token_id,
          references(:users_tokens, type: :binary_id, on_delete: :delete_all),
          null: false

      add :purpose, :string, null: false
      add :code_hash, :binary, null: false
      add :sent_to, :citext, null: false
      add :attempts, :integer, null: false, default: 0
      add :expires_at, :"timestamp(3)", null: false

      timestamps(type: :"timestamp(3)", updated_at: false)
    end

    create unique_index(:account_challenges, [:session_token_id, :purpose])
    create index(:account_challenges, [:user_id])
  end
end
