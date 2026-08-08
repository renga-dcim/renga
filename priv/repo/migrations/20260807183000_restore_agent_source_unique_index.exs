defmodule Renga.Repo.Migrations.RestoreAgentSourceUniqueIndex do
  use Ecto.Migration

  def up do
    drop_if_exists unique_index(:agents, [:organization_id, :source_id, :name])

    execute("""
    DO $$
    DECLARE
      duplicate_keys text;
    BEGIN
      SELECT string_agg(format('(organization_id=%s, source_id=%s)', organization_id, source_id), ', ')
      INTO duplicate_keys
      FROM (
        SELECT organization_id, source_id
        FROM agents
        GROUP BY organization_id, source_id
        HAVING count(*) > 1
        ORDER BY organization_id, source_id
      ) AS duplicates;

      IF duplicate_keys IS NOT NULL THEN
        RAISE EXCEPTION 'duplicate agent source identities prevent unique index creation: %', duplicate_keys
          USING HINT = 'Remediate the listed agents so each organization/source pair has only one agent, then rerun the migration. No data was deleted.';
      END IF;
    END
    $$
    """)

    create_if_not_exists unique_index(:agents, [:organization_id, :source_id])
  end

  def down do
    drop_if_exists unique_index(:agents, [:organization_id, :source_id])
    create_if_not_exists unique_index(:agents, [:organization_id, :source_id, :name])
  end
end
