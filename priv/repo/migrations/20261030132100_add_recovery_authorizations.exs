defmodule Renga.Repo.Migrations.AddRecoveryAuthorizations do
  use Ecto.Migration

  # RFD 19 "Recovery": spending a recovery code at sign-in grants the new
  # session five minutes to add one replacement factor.
  def change do
    drop constraint(:account_authorizations, :account_authorizations_valid_purpose)

    create constraint(:account_authorizations, :account_authorizations_valid_purpose,
             check: "purpose IN ('recheck', 'bootstrap', 'recovery')"
           )
  end
end
