defmodule Renga.Repo.Migrations.TrackAgentAuthenticationUsage do
  use Ecto.Migration

  def change do
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
