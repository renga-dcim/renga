defmodule Renga.Repo.Migrations.BindIdentityProviderAttempts do
  use Ecto.Migration

  # RFD 15: linking a provider from account settings is an attempt bound to
  # the signed-in session that started it. A sign-in attempt names neither,
  # and a callback completes an attempt only for the purpose it started
  # with. Ending the session deletes its attempts.
  def change do
    alter table(:identity_provider_attempts) do
      add :purpose, :string, null: false, default: "sign_in"
      add :user_id, references(:users, type: :binary_id, on_delete: :delete_all)

      add :session_token_id, references(:users_tokens, type: :binary_id, on_delete: :delete_all)
    end

    create constraint(:identity_provider_attempts, :purpose_binding,
             check:
               "(purpose = 'sign_in' AND user_id IS NULL AND session_token_id IS NULL) OR " <>
                 "(purpose = 'link' AND user_id IS NOT NULL AND session_token_id IS NOT NULL)"
           )
  end
end
