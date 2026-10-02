defmodule Renga.Repo.Migrations.CreatePrefixVlanRelationshipsTest do
  use ExUnit.Case, async: true

  @relationship_migration "priv/repo/migrations/20261002120000_create_prefix_vlan_relationships.exs"

  test "prefix and VLAN endpoints are tenant-scoped and removable from both sides" do
    migration = File.read!(@relationship_migration)

    assert migration =~
             "name: :prefix_vlan_relationships_tenant_prefix_fkey"

    assert migration =~ "name: :prefix_vlan_relationships_tenant_vlan_fkey"

    # Neither endpoint owns the association, so deleting a prefix or a VLAN only
    # removes the links; it must not be restricted or silently recreate them.
    assert migration =~
             ~r/add :prefix_id,\n\s+references\(:prefixes,\n\s+with: \[organization_id: :organization_id\],\n\s+on_delete: :delete_all/

    assert migration =~
             ~r/add :vlan_id,\n\s+references\(:vlans,\n\s+with: \[organization_id: :organization_id\],\n\s+on_delete: :delete_all/
  end

  test "the association identity is one link per organization, prefix, and VLAN" do
    migration = File.read!(@relationship_migration)

    assert migration =~ "name: :prefix_vlan_relationships_prefix_vlan_index"
    assert migration =~ "[:organization_id, :prefix_id, :vlan_id]"

    # The composite tenant foreign keys need the prefixes identity index.
    assert migration =~ "create unique_index(:prefixes, [:id, :organization_id])"
  end
end
