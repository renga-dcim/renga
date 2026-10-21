defmodule Renga.Repo.Migrations.CreateUserIdentities do
  use Ecto.Migration

  # RFD 15: a user's link to a provider subject. A returning sign-in matches
  # on (provider_id, subject) only, never on email.
  def change do
    create table(:user_identities, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :user_id, references(:users, type: :binary_id, on_delete: :delete_all), null: false

      add :provider_id, references(:identity_providers, type: :string, on_delete: :restrict),
        null: false

      add :subject, :string, null: false
      # The email the provider last asserted, for display only.
      add :email, :string
      add :last_signed_in_at, :"timestamp(3)"

      timestamps(type: :"timestamp(3)")
    end

    create unique_index(:user_identities, [:provider_id, :subject])
    create index(:user_identities, [:user_id])
  end
end
