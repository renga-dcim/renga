defmodule Renga.Repo.Migrations.CreateOperatorTokens do
  use Ecto.Migration

  # RFD 22: credentials for the operator API. They belong to the deployment,
  # not to an organization or user, and only a hash of each is stored.
  def change do
    create table(:operator_tokens) do
      add :name, :citext, null: false
      add :token_hash, :binary, null: false
      add :scopes, {:array, :string}, null: false
      # Empty means the token may be used from any address.
      add :allowed_sources, {:array, :cidr}, null: false, default: []
      add :expires_at, :"timestamp(3)"
      add :revoked_at, :"timestamp(3)"

      timestamps(type: :"timestamp(3)")
    end

    create unique_index(:operator_tokens, [:name])
    create unique_index(:operator_tokens, [:token_hash])
  end
end
