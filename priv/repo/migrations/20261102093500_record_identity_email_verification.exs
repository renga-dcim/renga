defmodule Renga.Repo.Migrations.RecordIdentityEmailVerification do
  use Ecto.Migration

  # RFD 15: whether the provider verified the address it last asserted for
  # an identity. Only a verified address from an organization's own
  # provider lets an account without a global email accept that
  # organization's invitation.
  def change do
    alter table(:user_identities) do
      add :email_verified, :boolean, null: false, default: false
    end
  end
end
