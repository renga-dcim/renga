defmodule Renga.Repo.Migrations.AllowRecheckProviderAttempts do
  use Ecto.Migration

  # RFD 15: an account with no passkey, authenticator app, or password passes
  # the account re-check by signing in again at a linked deployment provider.
  # Like a link, that attempt is bound to the user and session that started
  # it.
  def up do
    drop constraint(:identity_provider_attempts, :purpose_binding)

    create constraint(:identity_provider_attempts, :purpose_binding,
             check:
               "(purpose = 'sign_in' AND user_id IS NULL AND session_token_id IS NULL) OR " <>
                 "(purpose IN ('link', 'recheck') AND user_id IS NOT NULL AND " <>
                 "session_token_id IS NOT NULL)"
           )
  end

  def down do
    execute "DELETE FROM identity_provider_attempts WHERE purpose = 'recheck'"
    drop constraint(:identity_provider_attempts, :purpose_binding)

    create constraint(:identity_provider_attempts, :purpose_binding,
             check:
               "(purpose = 'sign_in' AND user_id IS NULL AND session_token_id IS NULL) OR " <>
                 "(purpose = 'link' AND user_id IS NOT NULL AND session_token_id IS NOT NULL)"
           )
  end
end
