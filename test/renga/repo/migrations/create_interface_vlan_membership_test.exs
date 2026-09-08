defmodule Renga.Repo.Migrations.CreateInterfaceVlanMembershipTest do
  use ExUnit.Case, async: true

  @membership_migration "priv/repo/migrations/20260908090000_create_interface_vlan_membership.exs"
  @hardening_migration "priv/repo/migrations/20260908120000_harden_interface_topology_evidence.exs"

  test "long evidence and finding identities remain rollback-safe" do
    membership = File.read!(@membership_migration)
    hardening = File.read!(@hardening_migration)

    assert membership =~ "add :source_local_key, :text, null: false"
    assert membership =~ "add :resolution_key, :text, null: false"
    refute hardening =~ "modify :source_local_key"
    refute hardening =~ "modify :resolution_key"
  end

  test "hot topology history lookups have supporting indexes" do
    membership = File.read!(@membership_migration)
    hardening = File.read!(@hardening_migration)

    assert membership =~ ":interface_vlan_evidence_active_source_key_index"
    assert membership =~ ":interface_vlan_evidence_active_interface_index"
    assert membership =~ ":interface_vlan_evidence_active_vlan_index"
    assert membership =~ ":interface_relationship_evidence_active_relationship_index"
    assert membership =~ "topology_findings_interface_history_index"
    assert hardening =~ "topology_snapshot_events_source_resource_section_index"
  end
end
