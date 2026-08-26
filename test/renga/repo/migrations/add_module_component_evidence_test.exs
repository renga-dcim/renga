defmodule Renga.Repo.Migrations.AddModuleComponentEvidenceTest do
  use ExUnit.Case, async: true

  @migration_path "priv/repo/migrations/20260826180000_add_module_component_evidence.exs"

  test "rollback removes derived module evidence before restoring the old kind constraint" do
    migration = File.read!(@migration_path)

    assert delete_offset =
             migration
             |> :binary.match("DELETE FROM component_evidence WHERE kind = 'module'")
             |> elem(0)

    assert down_offset = migration |> :binary.match("  def down do") |> elem(0)

    assert constraint_offset =
             migration
             |> :binary.match("kind IN ('cpu', 'memory', 'disk')")
             |> elem(0)

    assert down_offset < delete_offset
    assert delete_offset < constraint_offset
  end
end
