defmodule Renga.Repo.Migrations.AddModuleCompatibilityFindingsTest do
  use ExUnit.Case, async: true

  @migration_path "priv/repo/migrations/20260826190000_add_module_compatibility_findings.exs"

  test "rollback removes module findings before restoring the old kind constraint" do
    migration = File.read!(@migration_path)

    assert delete_offset =
             migration
             |> :binary.match("DELETE FROM component_findings WHERE kind IN")
             |> elem(0)

    assert down_offset = migration |> :binary.match("  def down do") |> elem(0)

    assert constraint_offset =
             migration
             |> :binary.match("replace_kind_constraint(@original_kinds)")
             |> elem(0)

    assert down_offset < delete_offset
    assert delete_offset < constraint_offset
  end
end
