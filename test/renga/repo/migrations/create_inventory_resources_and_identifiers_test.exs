defmodule Renga.Repo.Migrations.CreateInventoryResourcesAndIdentifiersTest do
  use ExUnit.Case, async: true

  @migration_path "priv/repo/migrations/20260731183310_create_inventory_resources_and_identifiers.exs"

  test "resource revision sequence creation has an explicit rollback command" do
    ast = @migration_path |> File.read!() |> Code.string_to_quoted!()

    {_ast, reversible?} =
      Macro.prewalk(ast, false, fn
        {:execute, _,
         [
           "CREATE SEQUENCE resource_revision_sequence AS bigint",
           "DROP SEQUENCE resource_revision_sequence"
         ]} = node,
        _found? ->
          {node, true}

        node, found? ->
          {node, found?}
      end)

    assert reversible?
  end
end
