defmodule Renga.Repo.Migrations.RemoveLegacySourceTokens do
  use Ecto.Migration

  def up do
    drop constraint(:agents, :agents_last_auth_method)

    alter table(:agents) do
      remove :last_auth_method
      remove :last_legacy_authenticated_at
    end

    alter table(:sources) do
      remove :token_hash
    end
  end

  def down do
    alter table(:sources) do
      add :token_hash, :binary
    end

    create unique_index(:sources, [:token_hash], where: "token_hash IS NOT NULL")

    alter table(:agents) do
      add :last_auth_method, :string
      add :last_legacy_authenticated_at, :"timestamp(3)"
    end

    create constraint(:agents, :agents_last_auth_method,
             check:
               "last_auth_method IS NULL OR last_auth_method IN ('intake_api_key', 'legacy_source_token')"
           )
  end
end
