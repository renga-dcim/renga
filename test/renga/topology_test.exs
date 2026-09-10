defmodule Renga.TopologyTest do
  use Renga.DataCase, async: true

  import Renga.AccountsFixtures
  import Renga.InventoryFixtures

  alias Renga.Accounts
  alias Renga.DCIM
  alias Renga.Inventory
  alias Renga.Inventory.ResourceRevision
  alias Renga.Inventory.ResourceStore
  alias Renga.Repo
  alias Renga.Topology
  alias Renga.Topology.CurrentInterfaceAdjacency
  alias Renga.Topology.InterfaceNeighborEvidence
  alias Renga.Topology.InterfaceVlanEvidence
  alias Renga.Topology.InterfaceVlanModeEvidence
  alias Renga.Topology.TopologySnapshotEvent
  alias Renga.Topology.Vlan

  setup do
    user = user_fixture()
    organization = organization_fixture()
    organization_membership_fixture(user, organization, %{role: "admin"})
    scope = Accounts.scope_for_user(user, organization.id)
    %{scope: scope, organization: organization}
  end

  test "reconciles stable LLDP endpoints and strengthens reciprocal adjacency confidence", %{
    scope: scope
  } do
    first_resource = resource_fixture(scope, "neighbor-first")
    second_resource = resource_fixture(scope, "neighbor-second")

    {:ok, first_interface} =
      Inventory.create_interface(scope, first_resource.id, %{
        name: "eth0",
        mac_address: "02:00:00:00:00:01"
      })

    {:ok, second_interface} =
      Inventory.create_interface(scope, second_resource.id, %{
        name: "Ethernet1",
        mac_address: "02:00:00:00:00:02"
      })

    {:ok, first_source} =
      Inventory.create_source(scope, %{kind: "manual", name: "neighbor-first"})

    {:ok, second_source} =
      Inventory.create_source(scope, %{kind: "manual", name: "neighbor-second"})

    first_observation =
      observation_fixture(scope, first_source, "neighbor-first", ~U[2026-09-10 12:00:00Z], %{})

    assert {:ok, [evidence]} =
             Topology.reconcile_interface_neighbors(
               scope,
               first_source,
               first_observation,
               first_resource.id,
               [
                 %{
                   "name" => "eth0",
                   "neighbors" => [neighbor("02:00:00:00:00:02", "02:00:00:00:00:02")]
                 }
               ],
               true
             )

    assert %{status: "matched", strategy: "stable_identifiers", remote_interface_id: remote_id} =
             Topology.get_interface_neighbor_match(scope, evidence.id)

    assert remote_id == second_interface.id
    assert [%{confidence: "reported"}] = Topology.list_current_interface_adjacencies(scope)

    assert_raise Postgrex.Error, ~r/interface neighbor evidence facts are immutable/, fn ->
      Repo.update_all(
        from(item in InterfaceNeighborEvidence, where: item.id == ^evidence.id),
        set: [remote_port_id: "changed"]
      )
    end

    assert Enum.any?(
             Topology.list_topology_findings(scope, first_interface.id),
             &(&1.kind == "asymmetric_neighbor")
           )

    second_observation =
      observation_fixture(scope, second_source, "neighbor-second", ~U[2026-09-10 12:01:00Z], %{})

    assert {:ok, [_]} =
             Topology.reconcile_interface_neighbors(
               scope,
               second_source,
               second_observation,
               second_resource.id,
               [
                 %{
                   "name" => "Ethernet1",
                   "neighbors" => [neighbor("02:00:00:00:00:01", "02:00:00:00:00:01")]
                 }
               ],
               true
             )

    assert [%{confidence: "reciprocal"}] = Topology.list_current_interface_adjacencies(scope)

    refute Enum.any?(
             Topology.list_topology_findings(scope, first_interface.id),
             &(&1.kind == "asymmetric_neighbor")
           )

    refute Enum.any?(
             Topology.list_topology_findings(scope, second_interface.id),
             &(&1.kind == "asymmetric_neighbor")
           )
  end

  test "keeps unresolved endpoints, expires evidence, and withdraws complete snapshots", %{
    scope: scope
  } do
    local_resource = resource_fixture(scope, "neighbor-lifecycle-local")
    remote_resource = resource_fixture(scope, "neighbor-lifecycle-remote")
    {:ok, local} = Inventory.create_interface(scope, local_resource.id, %{name: "eth0"})
    {:ok, remote} = Inventory.create_interface(scope, remote_resource.id, %{name: "swp1"})

    assert {:ok, _hostname} =
             Inventory.create_resource_identifier(scope, remote_resource.id, %{
               kind: "hostname",
               value: "neighbor-switch.example"
             })

    {:ok, source} =
      Inventory.create_source(scope, %{
        kind: "manual",
        name: "neighbor-lifecycle",
        metadata: %{"interface_neighbor_snapshot_policy" => "complete"}
      })

    unresolved_observation =
      observation_fixture(scope, source, "neighbor-unresolved", ~U[2026-09-10 13:00:00Z], %{})

    assert {:ok, [unresolved]} =
             Topology.reconcile_interface_neighbors(
               scope,
               source,
               unresolved_observation,
               local_resource.id,
               [%{"name" => "eth0", "neighbors" => [neighbor("missing-switch", "swp1")]}],
               true
             )

    assert %{status: "unresolved"} = Topology.get_interface_neighbor_match(scope, unresolved.id)

    assert Enum.any?(
             Topology.list_topology_findings(scope, local.id),
             &(&1.kind == "ambiguous_remote_identity")
           )

    matched_observation =
      observation_fixture(scope, source, "neighbor-matched", ~U[2026-09-10 13:01:00Z], %{})

    matched_neighbor = neighbor("neighbor-switch.example", remote.name, %{"ttl_seconds" => 30})

    assert {:ok, [matched]} =
             Topology.reconcile_interface_neighbors(
               scope,
               source,
               matched_observation,
               local_resource.id,
               [%{"name" => "eth0", "neighbors" => [matched_neighbor]}],
               true
             )

    assert %{status: "matched", strategy: "name_fallback"} =
             Topology.get_interface_neighbor_match(scope, matched.id)

    assert [%CurrentInterfaceAdjacency{}] = Topology.list_current_interface_adjacencies(scope)

    assert {:ok, []} =
             Topology.expire_interface_neighbors(scope, ~U[2026-09-10 13:01:31Z])

    assert Topology.list_current_interface_adjacencies(scope) == []
    assert DateTime.compare(Repo.reload!(matched).stale_at, ~U[2026-09-10 13:01:30Z]) == :eq

    assert Enum.any?(
             Topology.list_topology_findings(scope, local.id),
             &(&1.kind == "expired_adjacency")
           )

    fresh_observation =
      observation_fixture(scope, source, "neighbor-fresh", ~U[2026-09-10 13:02:00Z], %{
        "section_completeness" => %{"interface_neighbors" => true}
      })

    assert {:ok, [_]} =
             Topology.reconcile_interface_neighbors(
               scope,
               source,
               fresh_observation,
               local_resource.id,
               [
                 %{"name" => "eth0", "neighbors" => [neighbor(remote_resource.name, remote.name)]}
               ],
               true
             )

    withdrawal =
      observation_fixture(scope, source, "neighbor-withdrawal", ~U[2026-09-10 13:03:00Z], %{
        "section_completeness" => %{"interface_neighbors" => true}
      })

    assert {:ok, []} =
             Topology.reconcile_interface_neighbors(
               scope,
               source,
               withdrawal,
               local_resource.id,
               [%{"name" => "eth0", "neighbors" => []}],
               true
             )

    assert Topology.list_current_interface_adjacencies(scope) == []
    assert Enum.all?(Topology.list_interface_neighbor_evidence(scope, local.id), & &1.stale_at)
  end

  test "expires neighbor evidence across resources during reconciliation", %{scope: scope} do
    local_resource = resource_fixture(scope, "neighbor-global-expiry-local")
    remote_resource = resource_fixture(scope, "neighbor-global-expiry-remote")
    unrelated_resource = resource_fixture(scope, "neighbor-global-expiry-unrelated")
    {:ok, local} = Inventory.create_interface(scope, local_resource.id, %{name: "eth0"})
    {:ok, remote} = Inventory.create_interface(scope, remote_resource.id, %{name: "swp1"})
    {:ok, source} = Inventory.create_source(scope, %{kind: "manual", name: "global-expiry"})

    initial =
      observation_fixture(scope, source, "global-expiry-initial", ~U[2026-09-10 13:00:00Z], %{})

    assert {:ok, [evidence]} =
             Topology.reconcile_interface_neighbors(
               scope,
               source,
               initial,
               local_resource.id,
               [
                 %{
                   "name" => local.name,
                   "neighbors" => [
                     neighbor(remote_resource.name, remote.name, %{"ttl_seconds" => 30})
                   ]
                 }
               ],
               true
             )

    assert [_adjacency] = Topology.list_current_interface_adjacencies(scope)

    later =
      observation_fixture(scope, source, "global-expiry-later", ~U[2026-09-10 13:01:00Z], %{})

    assert {:ok, []} =
             Topology.reconcile_interface_neighbors(
               scope,
               source,
               later,
               unrelated_resource.id,
               [],
               true
             )

    assert Repo.reload!(evidence).stale_reason == "expired"
    assert Topology.list_current_interface_adjacencies(scope) == []
  end

  test "surfaces conflicting current neighbors without creating multiple canonical terminations",
       %{
         scope: scope
       } do
    local_resource = resource_fixture(scope, "neighbor-conflict-local")
    first_remote = resource_fixture(scope, "neighbor-conflict-first")
    second_remote = resource_fixture(scope, "neighbor-conflict-second")
    {:ok, local} = Inventory.create_interface(scope, local_resource.id, %{name: "eth0"})
    {:ok, first_port} = Inventory.create_interface(scope, first_remote.id, %{name: "swp1"})
    {:ok, second_port} = Inventory.create_interface(scope, second_remote.id, %{name: "swp1"})

    for {source_name, remote_resource, remote_port} <- [
          {"neighbor-conflict-a", first_remote, first_port},
          {"neighbor-conflict-b", second_remote, second_port}
        ] do
      {:ok, source} = Inventory.create_source(scope, %{kind: "manual", name: source_name})
      observation = observation_fixture(scope, source, source_name, ~U[2026-09-10 14:00:00Z], %{})

      assert {:ok, [_]} =
               Topology.reconcile_interface_neighbors(
                 scope,
                 source,
                 observation,
                 local_resource.id,
                 [
                   %{
                     "name" => "eth0",
                     "neighbors" => [neighbor(remote_resource.name, remote_port.name)]
                   }
                 ],
                 true
               )
    end

    assert [_one_selected] = Topology.list_current_interface_adjacencies(scope)

    assert Enum.any?(
             Topology.list_topology_findings(scope, local.id),
             &(&1.kind == "conflicting_neighbors")
           )
  end

  test "surfaces contention when multiple local interfaces report the same remote endpoint", %{
    scope: scope
  } do
    first_local_resource = resource_fixture(scope, "neighbor-contention-first")
    second_local_resource = resource_fixture(scope, "neighbor-contention-second")
    remote_resource = resource_fixture(scope, "neighbor-contention-remote")

    {:ok, first_local} =
      Inventory.create_interface(scope, first_local_resource.id, %{name: "eth0"})

    {:ok, second_local} =
      Inventory.create_interface(scope, second_local_resource.id, %{name: "eth0"})

    {:ok, remote} = Inventory.create_interface(scope, remote_resource.id, %{name: "swp1"})

    for {resource, interface, suffix} <- [
          {first_local_resource, first_local, "first"},
          {second_local_resource, second_local, "second"}
        ] do
      {:ok, source} =
        Inventory.create_source(scope, %{kind: "manual", name: "neighbor-contention-#{suffix}"})

      observation =
        observation_fixture(
          scope,
          source,
          "neighbor-contention-#{suffix}",
          ~U[2026-09-10 14:30:00Z],
          %{}
        )

      assert {:ok, [_]} =
               Topology.reconcile_interface_neighbors(
                 scope,
                 source,
                 observation,
                 resource.id,
                 [
                   %{
                     "name" => interface.name,
                     "neighbors" => [neighbor(remote_resource.name, remote.name)]
                   }
                 ],
                 true
               )
    end

    assert [_one_selected] = Topology.list_current_interface_adjacencies(scope)

    assert Enum.any?(
             Topology.list_topology_findings(scope, remote.id),
             &(&1.kind == "conflicting_neighbors")
           )
  end

  test "preserves ambiguous stable endpoint matches and rejects delayed neighbor resurrection", %{
    scope: scope
  } do
    local_resource = resource_fixture(scope, "neighbor-order-local")
    first_remote = resource_fixture(scope, "neighbor-order-first")
    second_remote = resource_fixture(scope, "neighbor-order-second")
    {:ok, local} = Inventory.create_interface(scope, local_resource.id, %{name: "eth0"})
    {:ok, first_port} = Inventory.create_interface(scope, first_remote.id, %{name: "swp1"})
    {:ok, second_port} = Inventory.create_interface(scope, second_remote.id, %{name: "swp1"})

    for resource <- [first_remote, second_remote] do
      assert {:ok, _identifier} =
               Inventory.create_resource_identifier(scope, resource.id, %{
                 kind: "external_id",
                 value: "duplicate-chassis"
               })
    end

    {:ok, source} = Inventory.create_source(scope, %{kind: "manual", name: "neighbor-order"})

    ambiguous_observation =
      observation_fixture(scope, source, "neighbor-ambiguous", ~U[2026-09-10 15:00:00Z], %{})

    assert {:ok, [ambiguous]} =
             Topology.reconcile_interface_neighbors(
               scope,
               source,
               ambiguous_observation,
               local_resource.id,
               [%{"name" => "eth0", "neighbors" => [neighbor("duplicate-chassis", "swp1")]}],
               true
             )

    assert %{status: "ambiguous", candidate_count: 2} =
             Topology.get_interface_neighbor_match(scope, ambiguous.id)

    assert Enum.any?(
             Topology.list_topology_findings(scope, local.id),
             &(&1.kind == "ambiguous_remote_identity")
           )

    newer = observation_fixture(scope, source, "neighbor-newer", ~U[2026-09-10 15:02:00Z], %{})

    assert {:ok, [_]} =
             Topology.reconcile_interface_neighbors(
               scope,
               source,
               newer,
               local_resource.id,
               [
                 %{
                   "name" => "eth0",
                   "neighbors" => [neighbor(first_remote.name, first_port.name)]
                 }
               ],
               true
             )

    older = observation_fixture(scope, source, "neighbor-older", ~U[2026-09-10 15:01:00Z], %{})

    assert {:ok, [delayed]} =
             Topology.reconcile_interface_neighbors(
               scope,
               source,
               older,
               local_resource.id,
               [
                 %{
                   "name" => "eth0",
                   "neighbors" => [neighbor(second_remote.name, second_port.name)]
                 }
               ],
               false
             )

    assert Repo.reload!(delayed).stale_reason == "superseded"
    assert [adjacency] = Topology.list_current_interface_adjacencies(scope)
    assert first_port.id in [adjacency.interface_a_id, adjacency.interface_b_id]
    refute second_port.id in [adjacency.interface_a_id, adjacency.interface_b_id]
  end

  test "creates resource-backed global VLAN namespaces and enforces valid ranges", %{scope: scope} do
    assert {:ok, group} = vlan_group_fixture(scope, "production", [{1, 100}, {200, 299}])
    assert group.resource.kind == "vlan_group"
    assert group.scope_kind == "global"
    assert Enum.map(group.vid_ranges, &{&1.start_vid, &1.end_vid}) == [{1, 100}, {200, 299}]

    assert {:ok, vlan} = vlan_fixture(scope, group, 42, "Applications")
    assert vlan.resource.kind == "vlan"
    assert vlan.resource.name == "#{group.id}/42"
    assert vlan.resource.display_name == "Applications"

    assert {:error, :vlan_out_of_range} = vlan_fixture(scope, group, 150, "Outside")

    assert {:error, %Ecto.Changeset{errors: [vid: {_, _}]}} =
             vlan_fixture(scope, group, 4095, "Reserved")
  end

  test "rejects overlapping ranges and range changes that strand VLANs", %{scope: scope} do
    assert {:error, :ranges_required} =
             Topology.create_vlan_group(
               scope,
               %{name: "No ranges", lifecycle_state: "active"},
               %{slug: "no-ranges"},
               []
             )

    assert {:error, %Ecto.Changeset{errors: [start_vid: {_, _}]}} =
             Topology.create_vlan_group(
               scope,
               %{name: "Overlapping ranges", lifecycle_state: "active"},
               %{slug: "overlapping-ranges"},
               [
                 %{start_vid: 1, end_vid: 100},
                 %{start_vid: 100, end_vid: 200}
               ]
             )

    assert {:ok, group} = vlan_group_fixture(scope, "range-change", [{1, 200}])
    assert {:ok, _vlan} = vlan_fixture(scope, group, 100, "Must remain valid")

    assert {:error, :vlan_out_of_range} =
             Topology.replace_vlan_group_ranges(scope, group, [
               %{start_vid: 101, end_vid: 200}
             ])

    stored = Topology.get_vlan_group!(scope, group.id)
    assert Enum.map(stored.vid_ranges, &{&1.start_vid, &1.end_vid}) == [{1, 200}]
  end

  test "uses one null-safe organization-global namespace for ungrouped VLANs", %{scope: scope} do
    assert {:ok, global} = vlan_fixture(scope, nil, 100, "Global")
    assert global.resource.name == "global/100"

    assert {:error, %Ecto.Changeset{}} = vlan_fixture(scope, nil, 100, "Duplicate global")

    assert {:ok, first_group} = vlan_group_fixture(scope, "first", [{1, 4094}])
    assert {:ok, second_group} = vlan_group_fixture(scope, "second", [{1, 4094}])
    assert {:ok, _first} = vlan_fixture(scope, first_group, 100, "First scoped")
    assert {:ok, _second} = vlan_fixture(scope, second_group, 100, "Second scoped")

    assert Enum.map(Topology.list_vlans(scope, nil), & &1.id) == [global.id]
  end

  test "supports typed site and location scopes with tenant-safe foreign keys", %{scope: scope} do
    site = site_fixture(scope, "topology-site")
    location = location_fixture(scope, site, "Network room")

    assert {:ok, site_group} =
             Topology.create_vlan_group(
               scope,
               %{name: "Site VLANs", lifecycle_state: "active"},
               %{slug: "site-vlans", scope_kind: "site", site_id: site.id},
               [%{start_vid: 1, end_vid: 4094}]
             )

    assert site_group.site.id == site.id

    assert {:ok, location_group} =
             Topology.create_vlan_group(
               scope,
               %{name: "Room VLANs", lifecycle_state: "active"},
               %{slug: "room-vlans", scope_kind: "location", location_id: location.id},
               [%{start_vid: 1, end_vid: 4094}]
             )

    assert location_group.location.id == location.id

    assert {:error, %Ecto.Changeset{errors: [scope_kind: {_, _}]}} =
             Topology.create_vlan_group(
               scope,
               %{name: "Invalid scope", lifecycle_state: "active"},
               %{slug: "invalid-scope", scope_kind: "site", location_id: location.id},
               [%{start_vid: 1, end_vid: 4094}]
             )

    other_user = user_fixture()
    other_organization = organization_fixture()
    organization_membership_fixture(other_user, other_organization, %{role: "admin"})
    other_scope = Accounts.scope_for_user(other_user, other_organization.id)

    assert {:error, %Ecto.Changeset{}} =
             Topology.create_vlan_group(
               other_scope,
               %{name: "Foreign site", lifecycle_state: "active"},
               %{slug: "foreign-site", scope_kind: "site", site_id: site.id},
               [%{start_vid: 1, end_vid: 4094}]
             )

    assert_raise Ecto.NoResultsError, fn ->
      Topology.get_vlan_group!(other_scope, site_group.id)
    end
  end

  test "updates VLAN identity and validates moves against the destination namespace", %{
    scope: scope
  } do
    assert {:ok, first_group} = vlan_group_fixture(scope, "source", [{1, 100}])
    assert {:ok, second_group} = vlan_group_fixture(scope, "destination", [{200, 300}])
    assert {:ok, vlan} = vlan_fixture(scope, first_group, 42, "Original")
    original_version = vlan.resource.resource_version
    original_generation = vlan.resource.generation
    original_revision_count = resource_revision_count(vlan.resource_id)

    assert {:error, :vlan_out_of_range} =
             Topology.update_vlan(scope, vlan, %{vid: 150})

    assert {:error, :vlan_out_of_range} =
             Topology.update_vlan(scope, vlan, %{vlan_group_id: second_group.id})

    assert resource_revision_count(vlan.resource_id) == original_revision_count

    unchanged = Topology.get_vlan!(scope, vlan.id)
    assert unchanged.resource.name == "#{first_group.id}/42"
    assert unchanged.resource.resource_version == original_version

    assert {:ok, updated} =
             Topology.update_vlan(scope, vlan, %{
               vlan_group_id: second_group.id,
               vid: 250,
               name: "Moved"
             })

    assert updated.vlan_group_id == second_group.id
    assert updated.vid == 250
    assert updated.resource.name == "#{second_group.id}/250"
    assert updated.resource.display_name == "Moved"
    assert updated.resource.resource_version > original_version
    assert updated.resource.generation == original_generation
    assert resource_revision_count(vlan.resource_id) == original_revision_count + 1

    latest_revision =
      ResourceRevision
      |> where([revision], revision.resource_id == ^vlan.resource_id)
      |> order_by([revision], desc: revision.revision)
      |> limit(1)
      |> Repo.one!()

    assert latest_revision.action == "updated"
    assert latest_revision.revision == updated.resource.resource_version
    assert latest_revision.snapshot["name"] == "#{second_group.id}/250"
    assert latest_revision.snapshot["display_name"] == "Moved"
  end

  test "active resolved membership evidence prevents in-place VLAN identity changes", %{
    scope: scope
  } do
    {:ok, first_group} = vlan_group_fixture(scope, "in-use-source", [{1, 100}])
    {:ok, second_group} = vlan_group_fixture(scope, "in-use-destination", [{1, 100}])
    {:ok, vlan} = vlan_fixture(scope, first_group, 10, "In use")
    resource = resource_fixture(scope, "in-use-vlan-server")
    {:ok, interface} = Inventory.create_interface(scope, resource.id, %{name: "eth0"})
    {:ok, source} = Inventory.create_source(scope, %{kind: "manual", name: "in-use-vlan-source"})
    {:ok, _mapping} = Topology.put_source_vlan_group_mapping(scope, source.id, first_group.id)

    {:ok, _desired} =
      Topology.put_desired_interface_vlan_assignment(scope, interface.id, vlan.id, %{
        tagging_mode: "tagged"
      })

    observation = observation_fixture(scope, source, "in-use-vlan", ~U[2026-09-08 14:00:00Z], %{})

    assert {:ok, [evidence]} =
             Topology.reconcile_interface_vlans(
               scope,
               source,
               observation,
               resource.id,
               [%{"name" => "eth0", "vlans" => [%{"vid" => 10, "tagging_mode" => "tagged"}]}],
               true
             )

    assert {:error, :vlan_identity_in_use} = Topology.update_vlan(scope, vlan, %{vid: 20})

    assert {:error, :vlan_identity_in_use} =
             Topology.update_vlan(scope, vlan, %{vlan_group_id: second_group.id})

    unchanged = Topology.get_vlan!(scope, vlan.id)
    assert unchanged.vid == 10
    assert unchanged.vlan_group_id == first_group.id

    assert [%{interface_vlan_evidence_id: evidence_id, vlan_id: vlan_id}] =
             Topology.list_current_interface_vlan_memberships(scope, interface.id)

    assert evidence_id == evidence.id
    assert vlan_id == vlan.id

    assert [%{id: ^evidence_id, vid: 10, stale_at: nil}] =
             Topology.list_interface_vlan_evidence(scope, interface.id)

    assert {:ok, renamed} = Topology.update_vlan(scope, vlan, %{name: "Still in use"})
    assert renamed.name == "Still in use"
    assert renamed.vid == 10
  end

  test "requires an active manager for namespace mutations", %{
    scope: scope,
    organization: organization
  } do
    viewer = user_fixture()
    organization_membership_fixture(viewer, organization, %{role: "viewer"})
    viewer_scope = Accounts.scope_for_user(viewer, organization.id)

    assert {:error, :forbidden} =
             Topology.create_vlan_group(
               viewer_scope,
               %{name: "Forbidden", lifecycle_state: "active"},
               %{slug: "forbidden"},
               [%{start_vid: 1, end_vid: 4094}]
             )

    assert {:ok, group} = vlan_group_fixture(scope, "private", [{1, 100}])
    assert {:error, :forbidden} = vlan_fixture(viewer_scope, group, 10, "Forbidden")
  end

  test "accepts consistently string-keyed resource attributes", %{scope: scope} do
    assert {:ok, group} =
             Topology.create_vlan_group(
               scope,
               %{"name" => "String keyed", "lifecycle_state" => "active"},
               %{"slug" => "string-keyed"},
               [%{"start_vid" => 1, "end_vid" => 100}]
             )

    assert group.resource.kind == "vlan_group"

    assert {:ok, vlan} =
             Topology.create_vlan(
               scope,
               %{"labels" => %{"origin" => "form"}},
               %{"vlan_group_id" => group.id, "vid" => 42, "name" => "String VLAN"}
             )

    assert vlan.resource.name == "#{group.id}/42"
    assert vlan.resource.labels == %{"origin" => "form"}
  end

  test "casts destination groups before locking during VLAN updates", %{scope: scope} do
    assert {:ok, group} = vlan_group_fixture(scope, "update-casting", [{1, 100}])
    assert {:ok, vlan} = vlan_fixture(scope, group, 42, "Applications")

    assert {:error, %Ecto.Changeset{errors: [vlan_group_id: {"is invalid", _}]}} =
             Topology.update_vlan(scope, vlan, %{"vlan_group_id" => "not-a-uuid"})

    assert {:ok, ungrouped} =
             Topology.update_vlan(scope, vlan, %{"vlan_group_id" => ""})

    assert is_nil(ungrouped.vlan_group_id)
    assert ungrouped.resource.name == "global/42"
  end

  test "blank VLAN names and group slugs return validation errors", %{scope: scope} do
    assert {:ok, group} = vlan_group_fixture(scope, "blank-validation", [{1, 100}])
    assert {:ok, vlan} = vlan_fixture(scope, group, 42, "Applications")

    assert {:error, %Ecto.Changeset{errors: [name: {"can't be blank", _}]}} =
             Topology.update_vlan(scope, vlan, %{"name" => ""})

    refute Topology.change_vlan(vlan, %{name: nil}).valid?

    assert {:error, %Ecto.Changeset{errors: [slug: {"can't be blank", _}]}} =
             Topology.update_vlan_group(scope, group, %{"slug" => ""})

    refute Topology.change_vlan_group(group, %{slug: nil}).valid?
  end

  test "malformed site and location scope IDs return validation errors", %{scope: scope} do
    assert {:error, %Ecto.Changeset{errors: [site_id: {"is invalid", _}]}} =
             Topology.create_vlan_group(
               scope,
               %{name: "Bad site", lifecycle_state: "active"},
               %{slug: "bad-site", scope_kind: "site", site_id: "not-a-uuid"},
               [%{start_vid: 1, end_vid: 100}]
             )

    assert {:ok, group} = vlan_group_fixture(scope, "scope-update", [{1, 100}])

    assert {:error, %Ecto.Changeset{errors: [location_id: {"is invalid", _}]}} =
             Topology.update_vlan_group(scope, group, %{
               scope_kind: "location",
               location_id: "not-a-uuid"
             })
  end

  test "16-byte non-UUID scope and group IDs return validation errors", %{scope: scope} do
    invalid_uuid = "warehouse worker"

    assert byte_size(invalid_uuid) == 16

    assert {:error, %Ecto.Changeset{errors: [site_id: {"is invalid", _}]}} =
             Topology.create_vlan_group(
               scope,
               %{name: "Bad binary site", lifecycle_state: "active"},
               %{slug: "bad-binary-site", scope_kind: "site", site_id: invalid_uuid},
               [%{start_vid: 1, end_vid: 100}]
             )

    assert {:ok, group} = vlan_group_fixture(scope, "binary-update", [{1, 100}])

    assert {:error, %Ecto.Changeset{errors: [location_id: {"is invalid", _}]}} =
             Topology.update_vlan_group(scope, group, %{
               scope_kind: "location",
               location_id: invalid_uuid
             })

    assert {:ok, vlan} = vlan_fixture(scope, nil, 42, "Applications")

    assert {:error, %Ecto.Changeset{errors: [vlan_group_id: {"is invalid", _}]}} =
             Topology.update_vlan(scope, vlan, %{vlan_group_id: invalid_uuid})

    assert {:ok, grouped} =
             Topology.update_vlan(scope, vlan, %{vlan_group_id: String.upcase(group.id)})

    assert grouped.vlan_group_id == group.id
    assert grouped.resource.name == "#{group.id}/42"
  end

  test "explicit null metadata returns validation errors", %{scope: scope} do
    assert {:error, %Ecto.Changeset{errors: [metadata: {"can't be blank", _}]}} =
             Topology.create_vlan_group(
               scope,
               %{name: "Null metadata", lifecycle_state: "active"},
               %{slug: "null-metadata", metadata: nil},
               [%{start_vid: 1, end_vid: 100}]
             )

    assert {:ok, group} = vlan_group_fixture(scope, "metadata-update", [{1, 100}])
    assert {:ok, vlan} = vlan_fixture(scope, group, 42, "Applications")

    assert {:error, %Ecto.Changeset{errors: [metadata: {"can't be blank", _}]}} =
             Topology.update_vlan_group(scope, group, %{metadata: nil})

    assert {:error, %Ecto.Changeset{errors: [metadata: {"can't be blank", _}]}} =
             Topology.update_vlan(scope, vlan, %{metadata: nil})

    assert Topology.get_vlan_group!(scope, group.id).metadata == %{}
    assert Topology.get_vlan!(scope, vlan.id).metadata == %{}
  end

  test "VLAN namespace strings respect database length boundaries", %{scope: scope} do
    max_value = String.duplicate("a", 255)
    oversized = String.duplicate("a", 256)

    assert {:ok, group} =
             Topology.create_vlan_group(
               scope,
               %{name: "Long slug", lifecycle_state: "active"},
               %{slug: max_value},
               [%{start_vid: 1, end_vid: 100}]
             )

    assert {:error, %Ecto.Changeset{errors: [slug: {_, _}]}} =
             Topology.update_vlan_group(scope, group, %{slug: oversized})

    assert {:ok, vlan} = vlan_fixture(scope, group, 42, max_value)
    assert {:ok, vlan} = Topology.update_vlan(scope, vlan, %{role: max_value})

    assert {:error, %Ecto.Changeset{errors: [name: {_, _}]}} =
             Topology.update_vlan(scope, vlan, %{name: oversized})

    assert {:error, %Ecto.Changeset{errors: [role: {_, _}]}} =
             Topology.update_vlan(scope, vlan, %{role: oversized})
  end

  test "database index rejects duplicate ungrouped VIDs independently of envelope names", %{
    scope: scope
  } do
    {:ok, first_resource} =
      ResourceStore.insert(scope.organization_id, %{
        kind: "vlan",
        name: "direct-global-100-a",
        lifecycle_state: "active"
      })

    {:ok, second_resource} =
      ResourceStore.insert(scope.organization_id, %{
        kind: "vlan",
        name: "direct-global-100-b",
        lifecycle_state: "active"
      })

    assert {:ok, _first_vlan} =
             %Vlan{organization_id: scope.organization_id, resource_id: first_resource.id}
             |> Vlan.changeset(%{vid: 100, name: "First"})
             |> Repo.insert()

    assert {:error, changeset} =
             %Vlan{organization_id: scope.organization_id, resource_id: second_resource.id}
             |> Vlan.changeset(%{vid: 100, name: "Second"})
             |> Repo.insert()

    assert Enum.any?(changeset.errors, fn {_field, {_message, options}} ->
             options[:constraint_name] == "vlans_organization_group_vid_index"
           end)
  end

  test "generic resource updates cannot change derived VLAN envelope identity", %{scope: scope} do
    assert {:ok, vlan} = vlan_fixture(scope, nil, 100, "Global 100")

    assert {:error, changeset} =
             Inventory.update_resource(scope, vlan.resource, %{
               name: "global/200",
               display_name: "Corrupted"
             })

    assert {"is managed by topology", _} = changeset.errors[:name]
    assert {"is managed by topology", _} = changeset.errors[:display_name]

    stored = Topology.get_vlan!(scope, vlan.id)
    assert stored.resource.name == "global/100"
    assert stored.resource.display_name == "Global 100"

    assert {:ok, _global_200} = vlan_fixture(scope, nil, 200, "Global 200")

    assert {:ok, updated_resource} =
             Inventory.update_resource(scope, stored.resource, %{
               labels: %{"managed" => "externally"}
             })

    assert updated_resource.labels == %{"managed" => "externally"}
  end

  test "generic resource creation cannot reserve topology-owned VLAN names", %{scope: scope} do
    assert {:error, changeset} =
             Inventory.create_resource(scope, %{
               kind: "vlan",
               name: "global/200",
               lifecycle_state: "active"
             })

    assert {"must be created through the topology context", _} = changeset.errors[:kind]
    assert {:ok, vlan} = vlan_fixture(scope, nil, 200, "Global 200")
    assert vlan.resource.name == "global/200"
  end

  test "keeps desired and current membership separate with layer-local untagged and mode rules",
       %{
         scope: scope
       } do
    resource = resource_fixture(scope, "membership-server")
    {:ok, interface} = Inventory.create_interface(scope, resource.id, %{name: "eth0"})
    {:ok, group} = vlan_group_fixture(scope, "membership", [{1, 100}])
    {:ok, native} = vlan_fixture(scope, group, 10, "Native")
    {:ok, tagged} = vlan_fixture(scope, group, 20, "Tagged")

    assert {:ok, %{mode: "access"}} =
             Topology.put_desired_interface_vlan_mode(scope, interface.id, %{mode: "access"})

    assert {:ok, assignment} =
             Topology.put_desired_interface_vlan_assignment(
               scope,
               interface.id,
               native.id,
               %{tagging_mode: "untagged"}
             )

    assert {:error, :invalid_interface_vlan_mode} =
             Topology.put_desired_interface_vlan_assignment(
               scope,
               interface.id,
               tagged.id,
               %{tagging_mode: "tagged"}
             )

    assert Topology.list_current_interface_vlan_memberships(scope, interface.id) == []
    assert [%{id: id}] = Topology.list_desired_interface_vlan_assignments(scope, interface.id)
    assert id == assignment.id

    assert {:ok, %{mode: "trunk"}} =
             Topology.put_desired_interface_vlan_mode(scope, interface.id, %{mode: "trunk"})

    assert {:ok, _tagged_assignment} =
             Topology.put_desired_interface_vlan_assignment(
               scope,
               interface.id,
               tagged.id,
               %{tagging_mode: "tagged"}
             )

    assert {:error, %Ecto.Changeset{}} =
             Topology.put_desired_interface_vlan_assignment(
               scope,
               interface.id,
               tagged.id,
               %{tagging_mode: "untagged"}
             )
  end

  test "metadata-only assignment upserts preserve access-compatible tagging", %{scope: scope} do
    resource = resource_fixture(scope, "membership-metadata-server")
    {:ok, interface} = Inventory.create_interface(scope, resource.id, %{name: "eth0"})
    {:ok, group} = vlan_group_fixture(scope, "membership-metadata", [{1, 100}])
    {:ok, vlan} = vlan_fixture(scope, group, 10, "Access")

    {:ok, _mode} =
      Topology.put_desired_interface_vlan_mode(scope, interface.id, %{mode: "access"})

    {:ok, assignment} =
      Topology.put_desired_interface_vlan_assignment(scope, interface.id, vlan.id, %{
        tagging_mode: "untagged"
      })

    assert {:ok, %{tagging_mode: "untagged", metadata: %{"note" => "kept"}}} =
             Topology.put_desired_interface_vlan_assignment(scope, interface.id, vlan.id, %{
               metadata: %{"note" => "kept"}
             })

    assert {:ok, %{id: id, tagging_mode: "untagged"}} =
             Topology.put_desired_interface_vlan_assignment(scope, interface.id, vlan.id, %{})

    assert id == assignment.id
  end

  test "resolves source-local VLAN evidence and only complete snapshots stale omissions", %{
    scope: scope
  } do
    resource = resource_fixture(scope, "observed-membership-server")
    {:ok, interface} = Inventory.create_interface(scope, resource.id, %{name: "eth0"})
    {:ok, group} = vlan_group_fixture(scope, "observed-membership", [{1, 100}])
    {:ok, vlan} = vlan_fixture(scope, group, 10, "Observed")

    {:ok, source} =
      Inventory.create_source(scope, %{
        kind: "manual",
        name: "vlan-source",
        metadata: %{"interface_vlan_snapshot_policy" => "complete"}
      })

    assert {:ok, _mapping} =
             Topology.put_source_vlan_group_mapping(scope, source.id, group.id)

    first = observation_fixture(scope, source, "vlan-first", ~U[2026-09-08 09:00:00.000Z], %{})

    assert {:ok, [_evidence]} =
             Topology.reconcile_interface_vlans(
               scope,
               source,
               first,
               resource.id,
               [
                 %{
                   "name" => "eth0",
                   "vlan_mode" => "trunk",
                   "vlans" => [%{"vid" => 10, "tagging_mode" => "tagged"}]
                 }
               ],
               true
             )

    assert %{mode: "trunk"} = Topology.get_current_interface_vlan_mode(scope, interface.id)

    assert [%{vlan_id: vlan_id, tagging_mode: "tagged"}] =
             Topology.list_current_interface_vlan_memberships(scope, interface.id)

    assert vlan_id == vlan.id

    partial =
      observation_fixture(scope, source, "vlan-partial", ~U[2026-09-08 09:01:00.000Z], %{})

    assert {:ok, []} =
             Topology.reconcile_interface_vlans(
               scope,
               source,
               partial,
               resource.id,
               [%{"name" => "eth0", "vlans" => []}],
               true
             )

    assert [_membership] = Topology.list_current_interface_vlan_memberships(scope, interface.id)

    complete =
      observation_fixture(
        scope,
        source,
        "vlan-complete",
        ~U[2026-09-08 09:02:00.000Z],
        %{"section_completeness" => %{"interface_vlans" => true}}
      )

    assert {:ok, []} =
             Topology.reconcile_interface_vlans(
               scope,
               source,
               complete,
               resource.id,
               [%{"name" => "eth0", "vlans" => []}],
               true
             )

    assert Topology.list_current_interface_vlan_memberships(scope, interface.id) == []
    assert is_nil(Topology.get_current_interface_vlan_mode(scope, interface.id))
    assert [%{stale_at: stale_at}] = Topology.list_interface_vlan_evidence(scope, interface.id)
    assert stale_at == complete.observed_at
  end

  test "retains unresolved source VLAN evidence without inventing current membership", %{
    scope: scope
  } do
    resource = resource_fixture(scope, "unresolved-membership-server")
    {:ok, interface} = Inventory.create_interface(scope, resource.id, %{name: "eth0"})

    {:ok, source} =
      Inventory.create_source(scope, %{kind: "manual", name: "unmapped-vlan-source"})

    observation =
      observation_fixture(scope, source, "unmapped-vlan", ~U[2026-09-08 10:00:00.000Z], %{})

    assert {:ok, [evidence]} =
             Topology.reconcile_interface_vlans(
               scope,
               source,
               observation,
               resource.id,
               [
                 %{
                   "name" => "eth0",
                   "vlans" => [%{"vid" => 10, "tagging_mode" => "untagged"}]
                 }
               ],
               true
             )

    assert is_nil(evidence.vlan_id)
    assert evidence.metadata["resolution"] == "unmapped_scope"
    assert Topology.list_current_interface_vlan_memberships(scope, interface.id) == []

    assert [%{kind: "unknown_vlan", status: "open"}] =
             Topology.list_topology_findings(scope, interface.id)
  end

  test "reports VLAN scope, range, and desired-versus-current findings", %{scope: scope} do
    resource = resource_fixture(scope, "membership-findings-server")
    {:ok, interface} = Inventory.create_interface(scope, resource.id, %{name: "eth0"})
    {:ok, first_group} = vlan_group_fixture(scope, "findings-first", [{1, 100}])
    {:ok, second_group} = vlan_group_fixture(scope, "findings-second", [{1, 100}])
    {:ok, desired_vlan} = vlan_fixture(scope, first_group, 10, "Desired")
    {:ok, unexpected_vlan} = vlan_fixture(scope, first_group, 20, "Unexpected")
    {:ok, missing_vlan} = vlan_fixture(scope, first_group, 30, "Missing")

    {:ok, source} =
      Inventory.create_source(scope, %{
        kind: "manual",
        name: "finding-vlan-source",
        metadata: %{"interface_vlan_snapshot_policy" => "complete"}
      })

    assert {:ok, _mapping} =
             Topology.put_source_vlan_group_mapping(scope, source.id, first_group.id, %{
               source_local_scope: "first"
             })

    assert {:ok, _mapping} =
             Topology.put_source_vlan_group_mapping(scope, source.id, second_group.id, %{
               source_local_scope: "second"
             })

    assert {:ok, _assignment} =
             Topology.put_desired_interface_vlan_assignment(
               scope,
               interface.id,
               desired_vlan.id,
               %{tagging_mode: "untagged"}
             )

    assert {:ok, _assignment} =
             Topology.put_desired_interface_vlan_assignment(
               scope,
               interface.id,
               missing_vlan.id,
               %{tagging_mode: "tagged"}
             )

    observation =
      observation_fixture(
        scope,
        source,
        "vlan-findings",
        ~U[2026-09-08 11:00:00.000Z],
        %{"section_completeness" => %{"interface_vlans" => true}}
      )

    assert {:ok, evidence} =
             Topology.reconcile_interface_vlans(
               scope,
               source,
               observation,
               resource.id,
               [
                 %{
                   "name" => "eth0",
                   "vlan_mode" => "trunk",
                   "vlans" => [
                     %{"vid" => 10, "scope" => "first", "tagging_mode" => "tagged"},
                     %{"vid" => 20, "scope" => "first", "tagging_mode" => "tagged"},
                     %{"vid" => 40, "tagging_mode" => "tagged"},
                     %{"vid" => 50, "scope" => "first", "tagging_mode" => "tagged"},
                     %{"vid" => 200, "scope" => "first", "tagging_mode" => "tagged"}
                   ]
                 }
               ],
               true
             )

    assert length(evidence) == 5
    assert Enum.find(evidence, &(&1.vid == 40)).metadata["resolution"] == "ambiguous_scope"
    assert Enum.find(evidence, &(&1.vid == 50)).metadata["resolution"] == "unknown_vlan"
    assert Enum.find(evidence, &(&1.vid == 200)).metadata["resolution"] == "out_of_range"

    kinds =
      scope
      |> Topology.list_topology_findings(interface.id)
      |> Enum.map(& &1.kind)
      |> MapSet.new()

    expected =
      MapSet.new(
        ~w(ambiguous_scope conflicting_tagging_mode missing_vlan out_of_range_vid unexpected_vlan unknown_vlan)
      )

    assert MapSet.subset?(expected, kinds)

    assert Enum.any?(
             Topology.list_current_interface_vlan_memberships(scope, interface.id),
             &(&1.vlan_id == unexpected_vlan.id)
           )
  end

  test "membership writes enforce manager authorization and tenant boundaries", %{
    scope: scope,
    organization: organization
  } do
    resource = resource_fixture(scope, "membership-authorization-server")
    {:ok, interface} = Inventory.create_interface(scope, resource.id, %{name: "eth0"})
    {:ok, group} = vlan_group_fixture(scope, "membership-authorization", [{1, 100}])
    {:ok, vlan} = vlan_fixture(scope, group, 10, "Authorized")

    {:ok, source} =
      Inventory.create_source(scope, %{kind: "manual", name: "mapping-authorization"})

    viewer = user_fixture()
    organization_membership_fixture(viewer, organization, %{role: "viewer"})
    viewer_scope = Accounts.scope_for_user(viewer, organization.id)

    assert {:error, :forbidden} =
             Topology.put_desired_interface_vlan_assignment(
               viewer_scope,
               interface.id,
               vlan.id,
               %{tagging_mode: "tagged"}
             )

    assert {:error, :forbidden} =
             Topology.put_source_vlan_group_mapping(viewer_scope, source.id, group.id)

    other_user = user_fixture()
    other_organization = organization_fixture()
    organization_membership_fixture(other_user, other_organization, %{role: "admin"})
    other_scope = Accounts.scope_for_user(other_user, other_organization.id)
    {:ok, other_group} = vlan_group_fixture(other_scope, "foreign-membership", [{1, 100}])
    {:ok, other_vlan} = vlan_fixture(other_scope, other_group, 10, "Foreign")

    assert_raise Ecto.NoResultsError, fn ->
      Topology.put_desired_interface_vlan_assignment(
        scope,
        interface.id,
        other_vlan.id,
        %{tagging_mode: "tagged"}
      )
    end

    assert_raise Ecto.NoResultsError, fn ->
      Topology.put_source_vlan_group_mapping(scope, source.id, other_group.id)
    end
  end

  test "mode evidence restores fallback sources and refuses an incompatible current mode", %{
    scope: scope
  } do
    resource = resource_fixture(scope, "mode-evidence-server")
    {:ok, interface} = Inventory.create_interface(scope, resource.id, %{name: "eth0"})
    {:ok, group} = vlan_group_fixture(scope, "mode-evidence", [{1, 100}])
    {:ok, _vlan} = vlan_fixture(scope, group, 10, "Tagged")
    {:ok, late_vlan} = vlan_fixture(scope, group, 20, "Historical")

    {:ok, source_a} =
      Inventory.create_source(scope, %{
        kind: "manual",
        name: "mode-source-a",
        metadata: %{"interface_vlan_snapshot_policy" => "complete"}
      })

    {:ok, source_b} =
      Inventory.create_source(scope, %{
        kind: "manual",
        name: "mode-source-b",
        metadata: %{"interface_vlan_snapshot_policy" => "complete"}
      })

    assert {:ok, _mapping} =
             Topology.put_source_vlan_group_mapping(scope, source_a.id, group.id)

    assert {:ok, _mapping} =
             Topology.put_source_vlan_group_mapping(scope, source_b.id, group.id)

    first = observation_fixture(scope, source_a, "mode-a", ~U[2026-08-30 12:00:00.000Z], %{})

    assert {:ok, [_evidence]} =
             Topology.reconcile_interface_vlans(
               scope,
               source_a,
               first,
               resource.id,
               [
                 %{
                   "name" => "eth0",
                   "vlan_mode" => "trunk",
                   "vlans" => [%{"vid" => 10, "tagging_mode" => "tagged"}]
                 }
               ],
               true
             )

    assert %{mode: "trunk"} = Topology.get_current_interface_vlan_mode(scope, interface.id)

    incompatible =
      observation_fixture(scope, source_b, "mode-b", ~U[2026-08-31 12:01:00.000Z], %{})

    assert {:ok, []} =
             Topology.reconcile_interface_vlans(
               scope,
               source_b,
               incompatible,
               resource.id,
               [%{"name" => "eth0", "vlan_mode" => "access"}],
               true
             )

    assert is_nil(Topology.get_current_interface_vlan_mode(scope, interface.id))

    assert Enum.any?(
             Topology.list_topology_findings(scope, interface.id),
             &(&1.kind == "conflicting_interface_mode")
           )

    withdrawal =
      observation_fixture(
        scope,
        source_b,
        "mode-b-withdrawal",
        ~U[2026-09-01 12:02:00.000Z],
        %{"section_completeness" => %{"interface_vlans" => true}}
      )

    assert {:ok, []} =
             Topology.reconcile_interface_vlans(
               scope,
               source_b,
               withdrawal,
               resource.id,
               [%{"name" => "eth0"}],
               true
             )

    assert %{mode: "trunk"} = Topology.get_current_interface_vlan_mode(scope, interface.id)
    assert length(Topology.list_interface_vlan_mode_evidence(scope, interface.id)) == 3

    late =
      observation_fixture(scope, source_b, "mode-b-late", ~U[2026-08-31 12:02:00.000Z], %{})

    assert {:ok, [_historical_evidence]} =
             Topology.reconcile_interface_vlans(
               scope,
               source_b,
               late,
               resource.id,
               [
                 %{
                   "name" => "eth0",
                   "vlan_mode" => "trunk",
                   "vlans" => [%{"vid" => 20, "tagging_mode" => "tagged"}]
                 }
               ],
               false
             )

    assert %{mode: "trunk"} = Topology.get_current_interface_vlan_mode(scope, interface.id)

    refute Enum.any?(
             Topology.list_current_interface_vlan_memberships(scope, interface.id),
             &(&1.vlan_id == late_vlan.id)
           )
  end

  test "normalizes global mappings and replays long source-local VLAN keys idempotently", %{
    scope: scope
  } do
    resource = resource_fixture(scope, "global-mapping-server")
    {:ok, interface} = Inventory.create_interface(scope, resource.id, %{name: "eth0"})
    {:ok, vlan} = vlan_fixture(scope, nil, 10, "Global")
    {:ok, source} = Inventory.create_source(scope, %{kind: "manual", name: "global-source"})

    assert {:ok, _mapping} =
             Topology.put_source_vlan_group_mapping(scope, source.id, nil, %{
               source_local_scope: " default "
             })

    observation = observation_fixture(scope, source, "global-key", ~U[2026-09-08 13:00:00Z], %{})
    key = "  " <> String.duplicate("source-key-", 30)
    unresolved_key = String.duplicate("unresolved-key-", 25)

    reported = [
      %{
        "name" => "eth0",
        "vlans" => [
          %{"key" => key, "scope" => " default ", "vid" => 10, "tagging_mode" => "tagged"},
          %{
            "key" => unresolved_key,
            "scope" => "other",
            "vid" => 11,
            "tagging_mode" => "tagged"
          }
        ]
      }
    ]

    assert {:ok, evidence} =
             Topology.reconcile_interface_vlans(
               scope,
               source,
               observation,
               resource.id,
               reported,
               true
             )

    assert Enum.any?(evidence, &(&1.vlan_id == vlan.id))

    assert {:ok, replayed_evidence} =
             Topology.reconcile_interface_vlans(
               scope,
               source,
               observation,
               resource.id,
               reported,
               true
             )

    assert length(replayed_evidence) == 2
    stored_evidence = Topology.list_interface_vlan_evidence(scope, interface.id)
    assert length(stored_evidence) == 2
    assert Enum.any?(stored_evidence, &(&1.source_local_key == String.trim(key)))

    assert Enum.any?(
             Topology.list_topology_findings(scope, interface.id),
             &String.ends_with?(&1.resolution_key, unresolved_key)
           )
  end

  test "mapping validation rejects non-string scopes instead of raising", %{scope: scope} do
    {:ok, source} =
      Inventory.create_source(scope, %{kind: "manual", name: "invalid-scope-source"})

    {:ok, first_group} = vlan_group_fixture(scope, "mapping-validation-first", [{1, 100}])
    {:ok, second_group} = vlan_group_fixture(scope, "mapping-validation-second", [{1, 100}])
    {:ok, original} = Topology.put_source_vlan_group_mapping(scope, source.id, first_group.id)

    assert {:error, changeset} =
             Topology.put_source_vlan_group_mapping(scope, source.id, nil, %{
               source_local_scope: 123
             })

    assert "is invalid" in errors_on(changeset).source_local_scope

    assert {:error, false_changeset} =
             Topology.put_source_vlan_group_mapping(scope, source.id, second_group.id, %{
               source_local_scope: false
             })

    assert "is invalid" in errors_on(false_changeset).source_local_scope
    assert %{id: id, vlan_group_id: group_id} = Repo.reload!(original)
    assert id == original.id
    assert group_id == first_group.id

    for attrs <- [%{source_local_scope: nil}, %{"source_local_scope" => nil}] do
      assert {:error, nil_changeset} =
               Topology.put_source_vlan_group_mapping(
                 scope,
                 source.id,
                 second_group.id,
                 attrs
               )

      assert "can't be blank" in errors_on(nil_changeset).source_local_scope
      assert Repo.reload!(original).vlan_group_id == first_group.id
    end

    assert {:error, unicode_changeset} =
             Topology.put_source_vlan_group_mapping(scope, source.id, nil, %{
               source_local_scope: String.duplicate("e\u0301", 128)
             })

    assert "should be at most 255 character(s)" in errors_on(unicode_changeset).source_local_scope

    assert {:ok, %{source_local_scope: boundary_scope}} =
             Topology.put_source_vlan_group_mapping(scope, source.id, nil, %{
               source_local_scope: String.duplicate("x", 255)
             })

    assert String.length(boundary_scope) == 255
  end

  test "repeated reports preserve each evidence row's original staleness transition", %{
    scope: scope
  } do
    resource = resource_fixture(scope, "stable-staleness-server")
    {:ok, interface} = Inventory.create_interface(scope, resource.id, %{name: "eth0"})
    {:ok, group} = vlan_group_fixture(scope, "stable-staleness", [{1, 100}])
    {:ok, _vlan} = vlan_fixture(scope, group, 10, "Stable")

    {:ok, source} =
      Inventory.create_source(scope, %{kind: "manual", name: "stable-staleness-source"})

    {:ok, _mapping} = Topology.put_source_vlan_group_mapping(scope, source.id, group.id)

    reports =
      for {id, observed_at} <- [
            {"stable-1", ~U[2026-09-08 13:00:00Z]},
            {"stable-2", ~U[2026-09-08 14:00:00Z]},
            {"stable-3", ~U[2026-09-08 15:00:00Z]}
          ] do
        observation = observation_fixture(scope, source, id, observed_at, %{})

        assert {:ok, [_]} =
                 Topology.reconcile_interface_vlans(
                   scope,
                   source,
                   observation,
                   resource.id,
                   [
                     %{
                       "name" => "eth0",
                       "vlans" => [%{"vid" => 10, "tagging_mode" => "tagged"}]
                     }
                   ],
                   true
                 )

        observation
      end

    [third, second, first] = Topology.list_interface_vlan_evidence(scope, interface.id)
    [first_observation, second_observation, _third_observation] = reports
    assert first.stale_at == second_observation.observed_at
    assert second.stale_at == third.observed_at
    assert is_nil(third.stale_at)
    assert first.observation_id == first_observation.id
  end

  test "same-observation source keys use stable lexical precedence for one canonical VLAN", %{
    scope: scope
  } do
    resource = resource_fixture(scope, "stable-membership-precedence-server")
    {:ok, interface} = Inventory.create_interface(scope, resource.id, %{name: "eth0"})
    {:ok, group} = vlan_group_fixture(scope, "stable-membership-precedence", [{1, 100}])
    {:ok, vlan} = vlan_fixture(scope, group, 10, "Shared identity")
    {:ok, _other_vlan} = vlan_fixture(scope, group, 20, "Unrelated")

    {:ok, source} =
      Inventory.create_source(scope, %{kind: "manual", name: "stable-membership-source"})

    {:ok, _mapping} = Topology.put_source_vlan_group_mapping(scope, source.id, group.id)

    first =
      observation_fixture(scope, source, "stable-membership-first", ~U[2026-09-08 13:00:00Z], %{})

    assert {:ok, evidence} =
             Topology.reconcile_interface_vlans(
               scope,
               source,
               first,
               resource.id,
               [
                 %{
                   "name" => "eth0",
                   "vlans" => [
                     %{"key" => "a-key", "vid" => 10, "tagging_mode" => "untagged"},
                     %{"key" => "z-key", "vid" => 10, "tagging_mode" => "tagged"}
                   ]
                 }
               ],
               true
             )

    selected = Enum.find(evidence, &(&1.source_local_key == "z-key"))

    assert [%{vlan_id: vlan_id, tagging_mode: "tagged", interface_vlan_evidence_id: evidence_id}] =
             Topology.list_current_interface_vlan_memberships(scope, interface.id)

    assert vlan_id == vlan.id
    assert evidence_id == selected.id

    second =
      observation_fixture(
        scope,
        source,
        "stable-membership-second",
        ~U[2026-09-08 14:00:00Z],
        %{}
      )

    assert {:ok, [_]} =
             Topology.reconcile_interface_vlans(
               scope,
               source,
               second,
               resource.id,
               [
                 %{
                   "name" => "eth0",
                   "vlans" => [%{"key" => "unrelated", "vid" => 20, "tagging_mode" => "tagged"}]
                 }
               ],
               true
             )

    shared =
      Topology.list_current_interface_vlan_memberships(scope, interface.id)
      |> Enum.find(&(&1.vlan_id == vlan.id))

    assert shared.tagging_mode == "tagged"
    assert shared.interface_vlan_evidence_id == selected.id
  end

  test "source-local ordering prevents historical and unresolved evidence from reviving projections",
       %{
         scope: scope
       } do
    resource = resource_fixture(scope, "ordered-evidence-server")
    {:ok, interface} = Inventory.create_interface(scope, resource.id, %{name: "eth0"})
    {:ok, group} = vlan_group_fixture(scope, "ordered-evidence", [{1, 100}])
    {:ok, vlan} = vlan_fixture(scope, group, 10, "Ordered")
    {:ok, source} = Inventory.create_source(scope, %{kind: "manual", name: "ordered-source"})

    assert {:ok, _mapping} =
             Topology.put_source_vlan_group_mapping(scope, source.id, group.id, %{
               source_local_scope: "mapped"
             })

    older = observation_fixture(scope, source, "ordered-old", ~U[2026-09-08 13:00:00Z], %{})
    newer = observation_fixture(scope, source, "ordered-new", ~U[2026-09-08 14:00:00Z], %{})

    assert {:ok, [_]} =
             Topology.reconcile_interface_vlans(
               scope,
               source,
               newer,
               resource.id,
               [
                 %{
                   "name" => "eth0",
                   "vlans" => [
                     %{
                       "key" => "port-vlan",
                       "scope" => "missing",
                       "vid" => 10,
                       "tagging_mode" => "tagged"
                     }
                   ]
                 }
               ],
               true
             )

    [opened] = Topology.list_topology_findings(scope, interface.id)

    assert {:ok, [_]} =
             Topology.reconcile_interface_vlans(
               scope,
               source,
               older,
               resource.id,
               [
                 %{
                   "name" => "eth0",
                   "vlans" => [
                     %{
                       "key" => "port-vlan",
                       "scope" => "mapped",
                       "vid" => 10,
                       "tagging_mode" => "tagged"
                     }
                   ]
                 }
               ],
               false
             )

    assert Topology.list_current_interface_vlan_memberships(scope, interface.id) == []

    assert [%{id: id, last_observed_at: timestamp}] =
             Topology.list_topology_findings(scope, interface.id)

    assert id == opened.id
    assert timestamp == newer.observed_at

    refute Enum.any?(
             Topology.list_interface_vlan_evidence(scope, interface.id),
             &(&1.vlan_id == vlan.id and is_nil(&1.stale_at))
           )
  end

  test "complete resource boundaries suppress evidence for interfaces discovered later", %{
    scope: scope
  } do
    resource = resource_fixture(scope, "late-interface-server")

    {:ok, source} =
      Inventory.create_source(scope, %{
        kind: "manual",
        name: "late-interface-source",
        metadata: %{"interface_vlan_snapshot_policy" => "complete"}
      })

    {:ok, group} = vlan_group_fixture(scope, "late-interface", [{1, 100}])
    {:ok, _vlan} = vlan_fixture(scope, group, 10, "Late")
    {:ok, _mapping} = Topology.put_source_vlan_group_mapping(scope, source.id, group.id)

    boundary =
      observation_fixture(scope, source, "late-boundary", ~U[2026-09-08 14:00:00Z], %{
        "section_completeness" => %{"interface_vlans" => true}
      })

    assert {:ok, []} =
             Topology.reconcile_interface_vlans(scope, source, boundary, resource.id, [], true)

    {:ok, interface} = Inventory.create_interface(scope, resource.id, %{name: "eth0"})
    delayed = observation_fixture(scope, source, "late-report", ~U[2026-09-08 13:00:00Z], %{})

    assert {:ok, [_]} =
             Topology.reconcile_interface_vlans(
               scope,
               source,
               delayed,
               resource.id,
               [
                 %{
                   "name" => "eth0",
                   "vlan_mode" => "trunk",
                   "vlans" => [%{"vid" => 10, "tagging_mode" => "tagged"}]
                 }
               ],
               false
             )

    assert Topology.list_current_interface_vlan_memberships(scope, interface.id) == []
    assert is_nil(Topology.get_current_interface_vlan_mode(scope, interface.id))
  end

  test "positive partial evidence resolves missing drift and desired mutations refresh findings",
       %{
         scope: scope
       } do
    resource = resource_fixture(scope, "finding-refresh-server")
    {:ok, interface} = Inventory.create_interface(scope, resource.id, %{name: "eth0"})
    {:ok, group} = vlan_group_fixture(scope, "finding-refresh", [{1, 100}])
    {:ok, vlan} = vlan_fixture(scope, group, 10, "Desired")

    {:ok, source} =
      Inventory.create_source(scope, %{
        kind: "manual",
        name: "finding-refresh-source",
        metadata: %{"interface_vlan_snapshot_policy" => "complete"}
      })

    {:ok, _mapping} = Topology.put_source_vlan_group_mapping(scope, source.id, group.id)

    {:ok, _assignment} =
      Topology.put_desired_interface_vlan_assignment(scope, interface.id, vlan.id, %{
        tagging_mode: "tagged"
      })

    complete =
      observation_fixture(scope, source, "finding-empty", ~U[2026-09-08 14:00:00Z], %{
        "section_completeness" => %{"interface_vlans" => true}
      })

    assert {:ok, []} =
             Topology.reconcile_interface_vlans(
               scope,
               source,
               complete,
               resource.id,
               [%{"name" => "eth0", "vlans" => []}],
               true
             )

    assert Enum.any?(
             Topology.list_topology_findings(scope, interface.id),
             &(&1.kind == "missing_vlan")
           )

    partial = observation_fixture(scope, source, "finding-present", ~U[2026-09-08 15:00:00Z], %{})

    assert {:ok, [_]} =
             Topology.reconcile_interface_vlans(
               scope,
               source,
               partial,
               resource.id,
               [%{"name" => "eth0", "vlans" => [%{"vid" => 10, "tagging_mode" => "tagged"}]}],
               true
             )

    refute Enum.any?(
             Topology.list_topology_findings(scope, interface.id),
             &(&1.kind == "missing_vlan")
           )

    assert {:ok, assignment} =
             Topology.put_desired_interface_vlan_assignment(scope, interface.id, vlan.id, %{
               tagging_mode: "untagged"
             })

    assert Enum.any?(
             Topology.list_topology_findings(scope, interface.id),
             &(&1.kind == "conflicting_tagging_mode")
           )

    assert {:ok, _} = Topology.delete_desired_interface_vlan_assignment(scope, assignment)

    refute Enum.any?(
             Topology.list_topology_findings(scope, interface.id),
             &(&1.kind == "conflicting_tagging_mode")
           )
  end

  test "reports desired-current and source-to-source interface mode drift", %{scope: scope} do
    resource = resource_fixture(scope, "mode-conflict-server")
    {:ok, interface} = Inventory.create_interface(scope, resource.id, %{name: "eth0"})
    {:ok, source_a} = Inventory.create_source(scope, %{kind: "manual", name: "mode-conflict-a"})
    {:ok, source_b} = Inventory.create_source(scope, %{kind: "manual", name: "mode-conflict-b"})

    {:ok, _} = Topology.put_desired_interface_vlan_mode(scope, interface.id, %{mode: "access"})

    assert Enum.any?(
             Topology.list_topology_findings(scope, interface.id),
             &(&1.resolution_key == "desired_mode")
           )

    first = observation_fixture(scope, source_a, "mode-conflict-a", ~U[2026-09-08 14:00:00Z], %{})

    second =
      observation_fixture(scope, source_b, "mode-conflict-b", ~U[2026-09-08 15:00:00Z], %{})

    assert {:ok, []} =
             Topology.reconcile_interface_vlans(
               scope,
               source_a,
               first,
               resource.id,
               [%{"name" => "eth0", "vlan_mode" => "access"}],
               true
             )

    assert {:ok, []} =
             Topology.reconcile_interface_vlans(
               scope,
               source_b,
               second,
               resource.id,
               [%{"name" => "eth0", "vlan_mode" => "trunk"}],
               true
             )

    keys = Topology.list_topology_findings(scope, interface.id) |> Enum.map(& &1.resolution_key)
    assert "desired_mode" in keys
    assert "source_modes" in keys

    {:ok, _} = Topology.put_desired_interface_vlan_mode(scope, interface.id, %{mode: "trunk"})

    refute Enum.any?(
             Topology.list_topology_findings(scope, interface.id),
             &(&1.resolution_key == "desired_mode")
           )
  end

  test "positive evidence resolves desired-write findings without moving lifecycle time backward",
       %{
         scope: scope
       } do
    resource = resource_fixture(scope, "finding-time-server")
    {:ok, interface} = Inventory.create_interface(scope, resource.id, %{name: "eth0"})
    {:ok, source} = Inventory.create_source(scope, %{kind: "manual", name: "finding-time-source"})

    assert {:ok, _mode} =
             Topology.put_desired_interface_vlan_mode(scope, interface.id, %{mode: "access"})

    opened =
      Topology.list_topology_findings(scope, interface.id)
      |> Enum.find(&(&1.resolution_key == "desired_mode"))

    assert opened

    historical =
      observation_fixture(scope, source, "finding-time-match", ~U[2020-01-01 00:00:00Z], %{})

    assert {:ok, []} =
             Topology.reconcile_interface_vlans(
               scope,
               source,
               historical,
               resource.id,
               [%{"name" => "eth0", "vlan_mode" => "access"}],
               false
             )

    refute Enum.any?(
             Topology.list_topology_findings(scope, interface.id),
             &(&1.resolution_key == "desired_mode")
           )

    resolved =
      scope
      |> Topology.list_topology_findings(interface.id, "resolved")
      |> Enum.find(&(&1.resolution_key == "desired_mode"))

    assert DateTime.compare(resolved.last_observed_at, opened.last_observed_at) in [:eq, :gt]
    assert DateTime.compare(resolved.resolved_at, opened.last_observed_at) in [:eq, :gt]
  end

  test "finding recurrence stays after the prior operator-driven resolution", %{scope: scope} do
    resource = resource_fixture(scope, "finding-recurrence-server")
    {:ok, interface} = Inventory.create_interface(scope, resource.id, %{name: "eth0"})

    {:ok, source} =
      Inventory.create_source(scope, %{kind: "manual", name: "finding-recurrence-source"})

    {:ok, _desired} =
      Topology.put_desired_interface_vlan_mode(scope, interface.id, %{mode: "access"})

    first =
      observation_fixture(
        scope,
        source,
        "finding-recurrence-first",
        ~U[2020-01-01 09:00:00Z],
        %{}
      )

    assert {:ok, []} =
             Topology.reconcile_interface_vlans(
               scope,
               source,
               first,
               resource.id,
               [%{"name" => "eth0", "vlan_mode" => "trunk"}],
               false
             )

    assert Enum.any?(
             Topology.list_topology_findings(scope, interface.id),
             &(&1.resolution_key == "desired_mode")
           )

    {:ok, _desired} =
      Topology.put_desired_interface_vlan_mode(scope, interface.id, %{mode: "trunk"})

    resolved =
      scope
      |> Topology.list_topology_findings(interface.id, "resolved")
      |> Enum.find(&(&1.resolution_key == "desired_mode"))

    assert resolved

    delayed =
      observation_fixture(
        scope,
        source,
        "finding-recurrence-delayed",
        ~U[2020-01-01 09:30:00Z],
        %{}
      )

    assert {:ok, []} =
             Topology.reconcile_interface_vlans(
               scope,
               source,
               delayed,
               resource.id,
               [%{"name" => "eth0", "vlan_mode" => "access"}],
               false
             )

    reopened =
      Topology.list_topology_findings(scope, interface.id)
      |> Enum.find(&(&1.resolution_key == "desired_mode"))

    assert reopened
    assert DateTime.compare(reopened.last_observed_at, resolved.resolved_at) in [:eq, :gt]
  end

  test "allows active members to reconcile while managed VLAN writes remain restricted", %{
    organization: organization,
    scope: admin_scope
  } do
    resource = resource_fixture(admin_scope, "member-reconciliation-server")
    {:ok, _interface} = Inventory.create_interface(admin_scope, resource.id, %{name: "eth0"})
    {:ok, source} = Inventory.create_source(admin_scope, %{kind: "manual", name: "member-source"})
    member = user_fixture()
    organization_membership_fixture(member, organization, %{role: "member"})
    member_scope = Accounts.scope_for_user(member, organization.id)

    observation =
      observation_fixture(admin_scope, source, "member-report", ~U[2026-09-08 14:00:00Z], %{})

    assert {:ok, []} =
             Topology.reconcile_interface_vlans(
               member_scope,
               source,
               observation,
               resource.id,
               [%{"name" => "eth0"}],
               true
             )

    assert {:error, :forbidden} =
             Topology.put_source_vlan_group_mapping(member_scope, source.id, nil)
  end

  test "evidence facts, mode evidence, and snapshot boundaries are immutable", %{scope: scope} do
    resource = resource_fixture(scope, "immutable-evidence-server")
    {:ok, interface} = Inventory.create_interface(scope, resource.id, %{name: "eth0"})

    {:ok, source} =
      Inventory.create_source(scope, %{
        kind: "manual",
        name: "immutable-source",
        metadata: %{"interface_vlan_snapshot_policy" => "complete"}
      })

    observation =
      observation_fixture(scope, source, "immutable-report", ~U[2026-09-08 14:00:00Z], %{
        "section_completeness" => %{"interface_vlans" => true}
      })

    assert {:ok, [evidence]} =
             Topology.reconcile_interface_vlans(
               scope,
               source,
               observation,
               resource.id,
               [
                 %{
                   "name" => "eth0",
                   "vlan_mode" => "trunk",
                   "vlans" => [%{"vid" => 10, "tagging_mode" => "tagged"}]
                 }
               ],
               true
             )

    [mode] = Topology.list_interface_vlan_mode_evidence(scope, interface.id)
    [event] = Repo.all(TopologySnapshotEvent)

    refute InterfaceVlanEvidence.changeset(evidence, %{vid: 20}).valid?
    refute InterfaceVlanModeEvidence.changeset(mode, %{mode: "access"}).valid?
    refute TopologySnapshotEvent.changeset(event, %{section: "interface_relationships"}).valid?

    assert_raise Postgrex.Error, ~r/interface VLAN evidence facts are immutable/, fn ->
      Repo.update_all(from(item in InterfaceVlanEvidence, where: item.id == ^evidence.id),
        set: [vid: 20]
      )
    end
  end

  test "database tenant foreign keys reject cross-organization topology evidence", %{scope: scope} do
    {:ok, source} =
      Inventory.create_source(scope, %{kind: "manual", name: "tenant-evidence-source"})

    observation =
      observation_fixture(scope, source, "tenant-evidence", ~U[2026-09-08 14:00:00Z], %{})

    foreign_user = user_fixture()
    foreign_organization = organization_fixture()
    organization_membership_fixture(foreign_user, foreign_organization, %{role: "admin"})
    foreign_scope = Accounts.scope_for_user(foreign_user, foreign_organization.id)
    foreign_resource = resource_fixture(foreign_scope, "foreign-evidence-server")

    {:ok, foreign_interface} =
      Inventory.create_interface(foreign_scope, foreign_resource.id, %{name: "eth0"})

    vlan_changeset =
      %InterfaceVlanEvidence{
        organization_id: scope.organization_id,
        interface_id: foreign_interface.id,
        source_id: source.id,
        observation_id: observation.id
      }
      |> InterfaceVlanEvidence.changeset(%{
        source_local_key: "default:10",
        vid: 10,
        tagging_mode: "tagged",
        metadata: %{},
        observed_at: observation.observed_at
      })

    assert {:error, rejected_vlan} = Repo.insert(vlan_changeset)
    assert "does not exist" in errors_on(rejected_vlan).interface

    neighbor_changeset =
      %InterfaceNeighborEvidence{
        organization_id: scope.organization_id,
        local_interface_id: foreign_interface.id,
        source_id: source.id,
        observation_id: observation.id
      }
      |> InterfaceNeighborEvidence.changeset(%{
        protocol: "lldp",
        remote_chassis_id: "switch.example",
        remote_port_id: "Ethernet1",
        ttl_seconds: 120,
        observed_at: observation.observed_at,
        expires_at: DateTime.add(observation.observed_at, 120, :second),
        metadata: %{}
      })

    assert {:error, rejected_neighbor} = Repo.insert(neighbor_changeset)
    assert "does not exist" in errors_on(rejected_neighbor).local_interface

    snapshot_changeset =
      %TopologySnapshotEvent{
        organization_id: scope.organization_id,
        resource_id: foreign_resource.id,
        source_id: source.id,
        observation_id: observation.id
      }
      |> TopologySnapshotEvent.changeset(%{
        section: "interface_vlans",
        observed_at: observation.observed_at
      })

    assert {:error, rejected_snapshot} = Repo.insert(snapshot_changeset)
    assert "does not exist" in errors_on(rejected_snapshot).resource
  end

  test "database rejects direct interface mode evidence mutation", %{scope: scope} do
    resource = resource_fixture(scope, "immutable-mode-server")
    {:ok, interface} = Inventory.create_interface(scope, resource.id, %{name: "eth0"})

    {:ok, source} =
      Inventory.create_source(scope, %{kind: "manual", name: "immutable-mode-source"})

    observation =
      observation_fixture(scope, source, "immutable-mode", ~U[2026-09-08 14:00:00Z], %{})

    assert {:ok, []} =
             Topology.reconcile_interface_vlans(
               scope,
               source,
               observation,
               resource.id,
               [%{"name" => "eth0", "vlan_mode" => "trunk"}],
               true
             )

    [mode] = Topology.list_interface_vlan_mode_evidence(scope, interface.id)

    assert_raise Postgrex.Error, ~r/interface VLAN mode evidence is immutable/, fn ->
      Repo.update_all(
        from(item in InterfaceVlanModeEvidence, where: item.id == ^mode.id),
        set: [mode: "access"]
      )
    end
  end

  test "database rejects direct topology snapshot boundary mutation", %{scope: scope} do
    resource = resource_fixture(scope, "immutable-snapshot-server")

    {:ok, source} =
      Inventory.create_source(scope, %{
        kind: "manual",
        name: "immutable-snapshot-source",
        metadata: %{"interface_vlan_snapshot_policy" => "complete"}
      })

    observation =
      observation_fixture(scope, source, "immutable-snapshot", ~U[2026-09-08 14:00:00Z], %{
        "section_completeness" => %{"interface_vlans" => true}
      })

    assert {:ok, []} =
             Topology.reconcile_interface_vlans(
               scope,
               source,
               observation,
               resource.id,
               [],
               true
             )

    event = Repo.get_by!(TopologySnapshotEvent, observation_id: observation.id)

    assert_raise Postgrex.Error, ~r/topology snapshot events are immutable/, fn ->
      Repo.update_all(
        from(item in TopologySnapshotEvent, where: item.id == ^event.id),
        set: [section: "interface_relationships"]
      )
    end
  end

  defp vlan_group_fixture(scope, slug, ranges) do
    Topology.create_vlan_group(
      scope,
      %{name: String.capitalize(slug), lifecycle_state: "active"},
      %{slug: slug, scope_kind: "global", status: "active"},
      Enum.map(ranges, fn {start_vid, end_vid} ->
        %{start_vid: start_vid, end_vid: end_vid}
      end)
    )
  end

  defp observation_fixture(scope, source, id, observed_at, payload) do
    {:ok, observation} =
      Inventory.create_observation(scope, source.id, %{
        idempotency_key: id,
        observed_at: observed_at,
        payload: payload
      })

    observation
  end

  defp neighbor(chassis_id, port_id, attrs \\ %{}) do
    Map.merge(
      %{
        "protocol" => "lldp",
        "remote_chassis_id" => chassis_id,
        "remote_port_id" => port_id,
        "ttl_seconds" => 120,
        "metadata" => %{}
      },
      attrs
    )
  end

  defp resource_fixture(scope, name) do
    {:ok, resource} =
      Inventory.create_resource(scope, %{
        kind: "server",
        name: name,
        lifecycle_state: "active"
      })

    resource
  end

  defp vlan_fixture(scope, group, vid, name) do
    Topology.create_vlan(
      scope,
      %{name: "ignored-by-topology"},
      %{vlan_group_id: group && group.id, vid: vid, name: name, status: "active"}
    )
  end

  defp site_fixture(scope, slug) do
    {:ok, site} =
      DCIM.create_site(
        scope,
        %{name: String.upcase(slug), lifecycle_state: "active"},
        %{slug: slug, status: "active", time_zone: "Etc/UTC"}
      )

    site
  end

  defp location_fixture(scope, site, name) do
    {:ok, location} =
      DCIM.create_location(
        scope,
        %{name: name, lifecycle_state: "active"},
        %{site_id: site.id, status: "active"}
      )

    location
  end

  defp resource_revision_count(resource_id) do
    ResourceRevision
    |> where([revision], revision.resource_id == ^resource_id)
    |> Repo.aggregate(:count)
  end
end
