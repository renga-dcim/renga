defmodule Renga.Repo.Migrations.AllowAccountsWithoutAGlobalEmail do
  use Ecto.Migration

  # RFD 15: signing up through an organization's identity provider creates
  # an account with no global login email. The address that provider
  # asserts stays on the identity, scoped to that organization, so it never
  # reserves the address against another account.
  def change do
    alter table(:users) do
      modify :email, :citext, null: true, from: {:citext, null: false}
    end
  end
end
