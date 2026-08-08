defmodule Renga.Repo.Migrations.RestoreAgentSourceUniqueIndexTest do
  use ExUnit.Case, async: true

  @migration_path "priv/repo/migrations/20260807183000_restore_agent_source_unique_index.exs"

  test "preflights duplicate organization/source identities without deleting data" do
    migration = File.read!(@migration_path)

    assert migration =~ "GROUP BY organization_id, source_id"
    assert migration =~ "HAVING count(*) > 1"
    assert migration =~ "organization_id=%s, source_id=%s"
    assert migration =~ "Remediate the listed agents"
    refute migration =~ ~r/\bDELETE\s+FROM\s+agents\b/i

    assert preflight_offset =
             :binary.match(migration, "duplicate agent source identities") |> elem(0)

    assert index_offset = :binary.match(migration, "create_if_not_exists unique_index") |> elem(0)
    assert preflight_offset < index_offset
  end
end
