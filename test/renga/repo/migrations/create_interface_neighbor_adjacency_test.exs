defmodule Renga.Repo.Migrations.CreateInterfaceNeighborAdjacencyTest do
  use ExUnit.Case, async: true

  @migration_path "priv/repo/migrations/20260910090000_create_interface_neighbor_adjacency.exs"

  test "rollback removes neighbor findings and snapshots before restoring old constraints" do
    migration = File.read!(@migration_path)

    assert migration =~
             ~r/DO \$\$\s+BEGIN\s+DELETE FROM topology_findings\s+WHERE kind IN \(\s+'ambiguous_remote_identity',\s+'asymmetric_neighbor',\s+'conflicting_neighbors',\s+'expired_adjacency'\s+\);\s+\n\s*DELETE FROM topology_snapshot_events\s+WHERE section = 'interface_neighbors';\s+\n\s*ALTER TABLE topology_snapshot_events/
  end
end
