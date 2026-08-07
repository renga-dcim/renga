defmodule Renga.Repo.Migrations.BindAgentInstallationIdentity do
  use Ecto.Migration

  def up do
    alter table(:agents) do
      add :installation_id, :uuid
    end

    execute("""
    DO $$
    BEGIN
      IF EXISTS (
        SELECT 1
        FROM agents
        WHERE metadata->>'installation_id' ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
        GROUP BY organization_id, (metadata->>'installation_id')::uuid
        HAVING count(*) > 1
      ) THEN
        RAISE EXCEPTION 'duplicate legacy agent installation IDs prevent credential binding'
          USING HINT = 'Assign each agent in an organization a distinct metadata.installation_id, then rerun the migration.';
      END IF;
    END
    $$
    """)

    execute("""
    UPDATE agents
    SET installation_id = (metadata->>'installation_id')::uuid
    WHERE metadata->>'installation_id' ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
    """)

    create unique_index(:agents, [:organization_id, :installation_id],
             where: "installation_id IS NOT NULL",
             name: :agents_organization_installation_id_index
           )
  end

  def down do
    drop_if_exists index(:agents, [:organization_id, :installation_id],
                     name: :agents_organization_installation_id_index
                   )

    alter table(:agents) do
      remove :installation_id
    end
  end
end
