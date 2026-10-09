defmodule Renga.TopologyTest do
  use Renga.DataCase, async: true

  import Renga.AccountsFixtures
  import Renga.InventoryFixtures

  alias Renga.Accounts
  alias Renga.DCIM
  alias Renga.Inventory
  alias Renga.Inventory.Host
  alias Renga.Inventory.Interface
  alias Renga.Inventory.Prefix
  alias Renga.Inventory.ResourceRevision
  alias Renga.Inventory.ResourceStore
  alias Renga.Repo
  alias Renga.Topology
  alias Renga.Topology.Cable
  alias Renga.Topology.CableAssertion
  alias Renga.Topology.CurrentInterfaceAdjacency
  alias Renga.Topology.InterfaceNeighborEvidence
  alias Renga.Topology.InterfaceNeighborMatch
  alias Renga.Topology.InterfaceVlanEvidence
  alias Renga.Topology.InterfaceVlanModeEvidence
  alias Renga.Topology.NeighborExpiryWorker
  alias Renga.Topology.NeighborIdentifier
  alias Renga.Topology.PrefixVlanRelationship
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
      observation_fixture(scope, first_source, "neighbor-first", ~U[2099-09-10 12:00:00Z], %{})

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

    assert_raise Postgrex.Error, ~r/interface_neighbor_evidence_stale_shape/, fn ->
      Repo.update_all(
        from(item in InterfaceNeighborEvidence, where: item.id == ^evidence.id),
        set: [stale_at: ~U[2099-09-10 12:00:30Z], stale_reason: nil]
      )
    end

    assert Enum.any?(
             Topology.list_topology_findings(scope, first_interface.id),
             &(&1.kind == "asymmetric_neighbor")
           )

    second_observation =
      observation_fixture(scope, second_source, "neighbor-second", ~U[2099-09-10 12:01:00Z], %{})

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
      observation_fixture(scope, source, "neighbor-unresolved", ~U[2099-09-10 13:00:00Z], %{})

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
      observation_fixture(scope, source, "neighbor-matched", ~U[2099-09-10 13:01:00Z], %{})

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
             Topology.expire_interface_neighbors(scope, ~U[2099-09-10 13:01:31Z])

    assert Topology.list_current_interface_adjacencies(scope) == []
    assert DateTime.compare(Repo.reload!(matched).stale_at, ~U[2099-09-10 13:01:30Z]) == :eq

    assert Enum.any?(
             Topology.list_topology_findings(scope, local.id),
             &(&1.kind == "expired_adjacency")
           )

    fresh_observation =
      observation_fixture(scope, source, "neighbor-fresh", ~U[2099-09-10 13:02:00Z], %{
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
      observation_fixture(scope, source, "neighbor-withdrawal", ~U[2099-09-10 13:03:00Z], %{
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

  test "does not let unrelated future observations expire neighbor evidence", %{scope: scope} do
    local_resource = resource_fixture(scope, "neighbor-global-expiry-local")
    remote_resource = resource_fixture(scope, "neighbor-global-expiry-remote")
    unrelated_resource = resource_fixture(scope, "neighbor-global-expiry-unrelated")
    {:ok, local} = Inventory.create_interface(scope, local_resource.id, %{name: "eth0"})
    {:ok, remote} = Inventory.create_interface(scope, remote_resource.id, %{name: "swp1"})
    {:ok, source} = Inventory.create_source(scope, %{kind: "manual", name: "global-expiry"})

    initial =
      observation_fixture(scope, source, "global-expiry-initial", ~U[2099-09-10 13:00:00Z], %{})

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
      observation_fixture(scope, source, "global-expiry-later", ~U[2199-09-10 13:01:00Z], %{})

    assert {:ok, []} =
             Topology.reconcile_interface_neighbors(
               scope,
               source,
               later,
               unrelated_resource.id,
               [],
               true
             )

    assert Repo.reload!(evidence).stale_at == nil
    assert [_adjacency] = Topology.list_current_interface_adjacencies(scope)

    assert [{:ok, []}] =
             NeighborExpiryWorker.sweep(~U[2099-09-10 13:00:31Z])

    assert Repo.reload!(evidence).stale_reason == "expired"
    assert Topology.list_current_interface_adjacencies(scope) == []
  end

  test "newly received evidence already expired by server time is never projected", %{
    scope: scope
  } do
    local_resource = resource_fixture(scope, "neighbor-received-expired-local")
    remote_resource = resource_fixture(scope, "neighbor-received-expired-remote")
    {:ok, local} = Inventory.create_interface(scope, local_resource.id, %{name: "eth0"})
    {:ok, remote} = Inventory.create_interface(scope, remote_resource.id, %{name: "swp1"})
    {:ok, source} = Inventory.create_source(scope, %{kind: "manual", name: "received-expired"})
    observed_at = DateTime.add(Renga.Time.utc_now_ms(), -60, :second)
    observation = observation_fixture(scope, source, "received-expired", observed_at, %{})

    assert {:ok, [evidence]} =
             reconcile_neighbors(scope, source, observation, local_resource, [
               %{
                 "name" => local.name,
                 "neighbors" => [
                   neighbor(remote_resource.name, remote.name, %{"ttl_seconds" => 30})
                 ]
               }
             ])

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
      observation = observation_fixture(scope, source, source_name, ~U[2099-09-10 14:00:00Z], %{})

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
          ~U[2099-09-10 14:30:00Z],
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

  test "database rejects current adjacencies that reuse either endpoint", %{scope: scope} do
    local_resource = resource_fixture(scope, "neighbor-occupancy-local")
    first_remote = resource_fixture(scope, "neighbor-occupancy-first")
    second_remote = resource_fixture(scope, "neighbor-occupancy-second")
    {:ok, local} = Inventory.create_interface(scope, local_resource.id, %{name: "eth0"})
    {:ok, first_port} = Inventory.create_interface(scope, first_remote.id, %{name: "swp1"})
    {:ok, second_port} = Inventory.create_interface(scope, second_remote.id, %{name: "swp1"})
    {:ok, source} = Inventory.create_source(scope, %{kind: "manual", name: "neighbor-occupancy"})

    observation =
      observation_fixture(scope, source, "neighbor-occupancy", ~U[2099-09-10 14:45:00Z], %{})

    assert {:ok, [evidence]} =
             reconcile_neighbors(scope, source, observation, local_resource, [
               %{
                 "name" => local.name,
                 "neighbors" => [neighbor(first_remote.name, first_port.name)]
               }
             ])

    [interface_a_id, interface_b_id] = Enum.sort([local.id, second_port.id])

    conflicting =
      %CurrentInterfaceAdjacency{
        organization_id: scope.organization_id,
        interface_a_id: interface_a_id,
        interface_b_id: interface_b_id,
        primary_evidence_id: evidence.id
      }
      |> CurrentInterfaceAdjacency.changeset(%{
        confidence: "reported",
        last_observed_at: observation.observed_at,
        metadata: %{}
      })

    assert_raise Ecto.ConstraintError, ~r/current_interface_adjacency_endpoints_pkey/, fn ->
      Repo.insert!(conflicting)
    end
  end

  test "database rejects direct occupancy mutation but permits adjacency cascades", %{
    scope: scope
  } do
    local_resource = resource_fixture(scope, "neighbor-occupancy-guard-local")
    remote_resource = resource_fixture(scope, "neighbor-occupancy-guard-remote")
    {:ok, local} = Inventory.create_interface(scope, local_resource.id, %{name: "eth0"})
    {:ok, remote} = Inventory.create_interface(scope, remote_resource.id, %{name: "swp1"})
    {:ok, unrelated} = Inventory.create_interface(scope, remote_resource.id, %{name: "swp2"})
    {:ok, source} = Inventory.create_source(scope, %{kind: "manual", name: "occupancy-guard"})

    observation =
      observation_fixture(scope, source, "occupancy-guard", ~U[2099-09-10 14:50:00Z], %{})

    assert {:ok, [_evidence]} =
             reconcile_neighbors(scope, source, observation, local_resource, [
               %{
                 "name" => local.name,
                 "neighbors" => [neighbor(remote_resource.name, remote.name)]
               }
             ])

    [adjacency] = Topology.list_current_interface_adjacencies(scope)

    assert_raise Postgrex.Error, ~r/current interface adjacency occupancy is inconsistent/, fn ->
      Repo.transaction(fn ->
        Repo.query!(
          "UPDATE current_interface_adjacency_endpoints SET interface_id = $1::text::uuid WHERE organization_id = $2::text::uuid AND interface_id = $3::text::uuid",
          [unrelated.id, scope.organization_id, local.id]
        )

        Repo.query!(
          "SET CONSTRAINTS current_interface_adjacency_endpoints_enforce_consistency IMMEDIATE"
        )
      end)
    end

    assert_raise Postgrex.Error, ~r/current interface adjacency occupancy is inconsistent/, fn ->
      Repo.transaction(fn ->
        Repo.query!(
          "DELETE FROM current_interface_adjacency_endpoints WHERE organization_id = $1::text::uuid AND interface_id = $2::text::uuid",
          [scope.organization_id, local.id]
        )

        Repo.query!(
          "SET CONSTRAINTS current_interface_adjacency_endpoints_enforce_consistency IMMEDIATE"
        )
      end)
    end

    assert %{rows: [[2]]} =
             Repo.query!(
               "SELECT count(*) FROM current_interface_adjacency_endpoints WHERE adjacency_id = $1::text::uuid",
               [adjacency.id]
             )

    Repo.delete!(adjacency)

    assert %{rows: [[0]]} =
             Repo.query!(
               "SELECT count(*) FROM current_interface_adjacency_endpoints WHERE adjacency_id = $1::text::uuid",
               [adjacency.id]
             )
  end

  test "preserves ambiguous matches and does not let delayed evidence replace newer adjacency", %{
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
      observation_fixture(scope, source, "neighbor-ambiguous", ~U[2099-09-10 15:00:00Z], %{})

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

    newer = observation_fixture(scope, source, "neighbor-newer", ~U[2099-09-10 15:02:00Z], %{})

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

    older = observation_fixture(scope, source, "neighbor-older", ~U[2099-09-10 15:01:00Z], %{})

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

    assert Repo.reload!(delayed).stale_at == nil
    assert [adjacency] = Topology.list_current_interface_adjacencies(scope)
    assert first_port.id in [adjacency.interface_a_id, adjacency.interface_b_id]
    refute second_port.id in [adjacency.interface_a_id, adjacency.interface_b_id]
  end

  test "retains delayed evidence behind a complete boundary without projecting it", %{
    scope: scope
  } do
    local_resource = resource_fixture(scope, "neighbor-delayed-boundary-local")
    remote_resource = resource_fixture(scope, "neighbor-delayed-boundary-remote")
    {:ok, local} = Inventory.create_interface(scope, local_resource.id, %{name: "eth0"})
    {:ok, remote} = Inventory.create_interface(scope, remote_resource.id, %{name: "swp1"})

    {:ok, source} =
      Inventory.create_source(scope, %{
        kind: "manual",
        name: "neighbor-delayed-boundary",
        metadata: %{"interface_neighbor_snapshot_policy" => "complete"}
      })

    boundary =
      observation_fixture(scope, source, "neighbor-boundary", ~U[2099-09-10 16:02:00Z], %{
        "section_completeness" => %{"interface_neighbors" => true}
      })

    assert {:ok, []} =
             reconcile_neighbors(scope, source, boundary, local_resource, [
               %{"name" => local.name, "neighbors" => []}
             ])

    delayed =
      observation_fixture(
        scope,
        source,
        "neighbor-before-boundary",
        ~U[2099-09-10 16:01:00Z],
        %{}
      )

    assert {:ok, [evidence]} =
             reconcile_neighbors(
               scope,
               source,
               delayed,
               local_resource,
               [
                 %{
                   "name" => local.name,
                   "neighbors" => [neighbor(remote_resource.name, remote.name)]
                 }
               ],
               false
             )

    assert Repo.reload!(evidence).stale_reason == "withdrawn"
    assert Topology.get_interface_neighbor_match(scope, evidence.id) == nil
    assert Topology.list_current_interface_adjacencies(scope) == []
  end

  test "expired newer evidence remains a barrier against delayed older reports", %{scope: scope} do
    local_resource = resource_fixture(scope, "neighbor-expired-order-local")
    remote_resource = resource_fixture(scope, "neighbor-expired-order-remote")
    {:ok, local} = Inventory.create_interface(scope, local_resource.id, %{name: "eth0"})
    {:ok, remote} = Inventory.create_interface(scope, remote_resource.id, %{name: "swp1"})
    {:ok, source} = Inventory.create_source(scope, %{kind: "manual", name: "expired-order"})

    newer = observation_fixture(scope, source, "expired-newer", ~U[2099-09-10 17:01:00Z], %{})

    assert {:ok, [_]} =
             reconcile_neighbors(scope, source, newer, local_resource, [
               %{
                 "name" => local.name,
                 "neighbors" => [
                   neighbor(remote_resource.name, remote.name, %{"ttl_seconds" => 30})
                 ]
               }
             ])

    assert {:ok, []} =
             Topology.expire_interface_neighbors(scope, ~U[2099-09-10 17:02:00Z])

    older = observation_fixture(scope, source, "expired-older", ~U[2099-09-10 17:00:00Z], %{})

    assert {:ok, [delayed]} =
             reconcile_neighbors(
               scope,
               source,
               older,
               local_resource,
               [
                 %{
                   "name" => local.name,
                   "neighbors" => [
                     neighbor(remote_resource.name, remote.name, %{"ttl_seconds" => 600})
                   ]
                 }
               ],
               false
             )

    assert Repo.reload!(delayed).stale_reason == "superseded"
    assert Topology.list_current_interface_adjacencies(scope) == []
  end

  test "equal-time conflicting adjacency selection respects observation ordering", %{scope: scope} do
    local_resource = resource_fixture(scope, "neighbor-equal-time-local")
    first_remote = resource_fixture(scope, "neighbor-equal-time-first")
    second_remote = resource_fixture(scope, "neighbor-equal-time-second")
    {:ok, local} = Inventory.create_interface(scope, local_resource.id, %{name: "eth0"})
    {:ok, first_port} = Inventory.create_interface(scope, first_remote.id, %{name: "swp1"})
    {:ok, second_port} = Inventory.create_interface(scope, second_remote.id, %{name: "swp1"})
    {:ok, source} = Inventory.create_source(scope, %{kind: "manual", name: "equal-time"})

    [{delayed_resource, delayed_port}, {newer_resource, newer_port}] =
      [{first_remote, first_port}, {second_remote, second_port}]
      |> Enum.sort_by(fn {_resource, port} -> Enum.sort([local.id, port.id]) end)

    observed_at = ~U[2099-09-10 17:05:00Z]
    delayed = observation_fixture(scope, source, "equal-time-delayed", observed_at, %{})
    newer = observation_fixture(scope, source, "equal-time-newer", observed_at, %{})

    assert delayed.id < newer.id

    assert {:ok, [_]} =
             reconcile_neighbors(
               scope,
               source,
               newer,
               local_resource,
               [
                 %{
                   "name" => local.name,
                   "neighbors" => [neighbor(newer_resource.name, newer_port.name)]
                 }
               ],
               false
             )

    assert {:ok, [_]} =
             reconcile_neighbors(
               scope,
               source,
               delayed,
               local_resource,
               [
                 %{
                   "name" => local.name,
                   "neighbors" => [neighbor(delayed_resource.name, delayed_port.name)]
                 }
               ],
               false
             )

    assert [adjacency] = Topology.list_current_interface_adjacencies(scope)
    assert newer_port.id in [adjacency.interface_a_id, adjacency.interface_b_id]
    refute delayed_port.id in [adjacency.interface_a_id, adjacency.interface_b_id]
  end

  test "already expired delayed evidence stays superseded after finding resolution", %{
    scope: scope
  } do
    local_resource = resource_fixture(scope, "neighbor-expired-delayed-local")
    remote_resource = resource_fixture(scope, "neighbor-expired-delayed-remote")
    {:ok, local} = Inventory.create_interface(scope, local_resource.id, %{name: "eth0"})
    {:ok, remote} = Inventory.create_interface(scope, remote_resource.id, %{name: "swp1"})
    {:ok, source} = Inventory.create_source(scope, %{kind: "manual", name: "expired-delayed"})
    as_of = Renga.Time.utc_now_ms()

    newer =
      observation_fixture(
        scope,
        source,
        "expired-delayed-newer",
        DateTime.add(as_of, -60, :second),
        %{}
      )

    assert {:ok, [newer_evidence]} =
             reconcile_neighbors(scope, source, newer, local_resource, [
               %{
                 "name" => local.name,
                 "neighbors" => [
                   neighbor(remote_resource.name, remote.name, %{"ttl_seconds" => 30})
                 ]
               }
             ])

    assert Repo.reload!(newer_evidence).stale_reason == "expired"
    assert [%{kind: "expired_adjacency"}] = Topology.list_topology_findings(scope, local.id)

    local
    |> Ecto.Changeset.change(status: "not_present")
    |> Repo.update!()

    assert {:ok, []} = Topology.refresh_interface_neighbors(scope)
    assert Topology.list_topology_findings(scope, local.id) == []

    local
    |> Ecto.Changeset.change(status: "up")
    |> Repo.update!()

    older =
      observation_fixture(
        scope,
        source,
        "expired-delayed-older",
        DateTime.add(as_of, -120, :second),
        %{}
      )

    assert {:ok, [delayed]} =
             reconcile_neighbors(
               scope,
               source,
               older,
               local_resource,
               [
                 %{
                   "name" => local.name,
                   "neighbors" => [
                     neighbor(remote_resource.name, remote.name, %{"ttl_seconds" => 30})
                   ]
                 }
               ],
               false
             )

    assert Repo.reload!(delayed).stale_reason == "superseded"
    assert Topology.list_topology_findings(scope, local.id) == []
  end

  test "partial snapshots retain omitted neighbor identities until complete withdrawal", %{
    scope: scope
  } do
    local_resource = resource_fixture(scope, "neighbor-partial-local")
    first_remote = resource_fixture(scope, "neighbor-partial-first")
    second_remote = resource_fixture(scope, "neighbor-partial-second")
    {:ok, local} = Inventory.create_interface(scope, local_resource.id, %{name: "eth0"})
    {:ok, first_port} = Inventory.create_interface(scope, first_remote.id, %{name: "swp1"})
    {:ok, second_port} = Inventory.create_interface(scope, second_remote.id, %{name: "swp1"})

    {:ok, source} =
      Inventory.create_source(scope, %{
        kind: "manual",
        name: "neighbor-partial",
        metadata: %{"interface_neighbor_snapshot_policy" => "complete"}
      })

    initial =
      observation_fixture(
        scope,
        source,
        "neighbor-partial-initial",
        ~U[2099-09-10 18:00:00Z],
        %{}
      )

    assert {:ok, [_first, second]} =
             reconcile_neighbors(scope, source, initial, local_resource, [
               %{
                 "name" => local.name,
                 "neighbors" => [
                   neighbor(first_remote.name, first_port.name),
                   neighbor(second_remote.name, second_port.name)
                 ]
               }
             ])

    partial =
      observation_fixture(scope, source, "neighbor-partial-update", ~U[2099-09-10 18:01:00Z], %{})

    assert {:ok, [_]} =
             reconcile_neighbors(scope, source, partial, local_resource, [
               %{
                 "name" => local.name,
                 "neighbors" => [neighbor(first_remote.name, first_port.name)]
               }
             ])

    assert Repo.reload!(second).stale_at == nil

    complete =
      observation_fixture(scope, source, "neighbor-partial-complete", ~U[2099-09-10 18:02:00Z], %{
        "section_completeness" => %{"interface_neighbors" => true}
      })

    assert {:ok, [_]} =
             reconcile_neighbors(scope, source, complete, local_resource, [
               %{
                 "name" => local.name,
                 "neighbors" => [neighbor(first_remote.name, first_port.name)]
               }
             ])

    assert Repo.reload!(second).stale_reason == "withdrawn"
  end

  test "prefers a unique stable port over a misleading system name", %{scope: scope} do
    local_resource = resource_fixture(scope, "neighbor-port-precedence-local")
    stable_resource = resource_fixture(scope, "neighbor-port-precedence-stable")
    misleading_resource = resource_fixture(scope, "neighbor-port-precedence-misleading")
    {:ok, local} = Inventory.create_interface(scope, local_resource.id, %{name: "eth0"})

    {:ok, stable_port} =
      Inventory.create_interface(scope, stable_resource.id, %{
        name: "Ethernet1",
        mac_address: "02:00:00:00:01:01"
      })

    {:ok, _misleading_port} =
      Inventory.create_interface(scope, misleading_resource.id, %{name: "Ethernet1"})

    {:ok, source} = Inventory.create_source(scope, %{kind: "manual", name: "port-precedence"})

    observation =
      observation_fixture(scope, source, "port-precedence", ~U[2099-09-10 19:00:00Z], %{})

    attrs =
      neighbor("unknown-chassis", "02:00:00:00:01:01", %{
        "remote_system_name" => misleading_resource.name,
        "remote_port_id_kind" => "mac_address",
        "remote_port_description" => "Ethernet1"
      })

    assert {:ok, [evidence]} =
             reconcile_neighbors(scope, source, observation, local_resource, [
               %{"name" => local.name, "neighbors" => [attrs]}
             ])

    assert %{status: "matched", remote_interface_id: remote_id} =
             Topology.get_interface_neighbor_match(scope, evidence.id)

    assert remote_id == stable_port.id
  end

  test "preserves case-sensitive stable identifiers during matching", %{scope: scope} do
    local_resource = resource_fixture(scope, "neighbor-case-local")
    exact_resource = resource_fixture(scope, "neighbor-case-exact")
    other_resource = resource_fixture(scope, "neighbor-case-other")
    {:ok, local} = Inventory.create_interface(scope, local_resource.id, %{name: "eth0"})
    {:ok, exact_port} = Inventory.create_interface(scope, exact_resource.id, %{name: "swp1"})
    {:ok, _other_port} = Inventory.create_interface(scope, other_resource.id, %{name: "swp1"})

    for {resource, value} <- [{exact_resource, "NodeABC"}, {other_resource, "nodeabc"}] do
      assert {:ok, _identifier} =
               Inventory.create_resource_identifier(scope, resource.id, %{
                 kind: "external_id",
                 value: value
               })
    end

    {:ok, source} = Inventory.create_source(scope, %{kind: "manual", name: "neighbor-case"})

    observation =
      observation_fixture(scope, source, "neighbor-case", ~U[2099-09-10 20:00:00Z], %{})

    assert {:ok, [evidence]} =
             reconcile_neighbors(scope, source, observation, local_resource, [
               %{"name" => local.name, "neighbors" => [neighbor("NodeABC", "swp1")]}
             ])

    assert %{status: "matched", remote_interface_id: remote_id} =
             Topology.get_interface_neighbor_match(scope, evidence.id)

    assert remote_id == exact_port.id
  end

  test "preserves MAC-shaped explicit local identifiers as opaque values", %{scope: scope} do
    local_resource = resource_fixture(scope, "neighbor-opaque-mac-local")
    upper_resource = resource_fixture(scope, "neighbor-opaque-mac-upper")
    lower_resource = resource_fixture(scope, "neighbor-opaque-mac-lower")
    {:ok, local} = Inventory.create_interface(scope, local_resource.id, %{name: "eth0"})
    {:ok, upper_port} = Inventory.create_interface(scope, upper_resource.id, %{name: "swp1"})
    {:ok, lower_port} = Inventory.create_interface(scope, lower_resource.id, %{name: "swp1"})

    for {resource, value} <- [{upper_resource, "AABBCCDDEEFF"}, {lower_resource, "aabbccddeeff"}] do
      assert {:ok, _identifier} =
               Inventory.create_resource_identifier(scope, resource.id, %{
                 kind: "external_id",
                 value: value
               })
    end

    {:ok, source} = Inventory.create_source(scope, %{kind: "manual", name: "opaque-mac"})
    observation = observation_fixture(scope, source, "opaque-mac", ~U[2099-09-10 20:01:00Z], %{})

    neighbors =
      for chassis_id <- ["AABBCCDDEEFF", "aabbccddeeff"] do
        neighbor(chassis_id, "swp1", %{
          "remote_chassis_id_kind" => "local",
          "remote_port_id_kind" => "name"
        })
      end

    assert {:ok, evidence} =
             reconcile_neighbors(scope, source, observation, local_resource, [
               %{"name" => local.name, "neighbors" => neighbors}
             ])

    assert Enum.uniq_by(evidence, & &1.id) == evidence

    assert Enum.map(evidence, & &1.remote_chassis_id_normalized) == [
             "AABBCCDDEEFF",
             "aabbccddeeff"
           ]

    assert evidence
           |> Enum.map(&Topology.get_interface_neighbor_match(scope, &1.id).remote_interface_id)
           |> Enum.sort() == Enum.sort([upper_port.id, lower_port.id])
  end

  test "does not match neighbor evidence to an interface that is not present", %{scope: scope} do
    local_resource = resource_fixture(scope, "neighbor-presence-local")
    remote_resource = resource_fixture(scope, "neighbor-presence-remote")
    {:ok, local} = Inventory.create_interface(scope, local_resource.id, %{name: "eth0"})

    {:ok, _removed_port} =
      Inventory.create_interface(scope, remote_resource.id, %{
        name: "swp1",
        mac_address: "02:00:00:00:02:01",
        status: "not_present"
      })

    {:ok, source} = Inventory.create_source(scope, %{kind: "manual", name: "neighbor-presence"})

    observation =
      observation_fixture(scope, source, "neighbor-presence", ~U[2099-09-10 21:00:00Z], %{})

    assert {:ok, [evidence]} =
             reconcile_neighbors(scope, source, observation, local_resource, [
               %{
                 "name" => local.name,
                 "neighbors" => [
                   neighbor(remote_resource.name, "02:00:00:00:02:01", %{
                     "remote_port_id_kind" => "mac_address"
                   })
                 ]
               }
             ])

    assert %{status: "unresolved"} = Topology.get_interface_neighbor_match(scope, evidence.id)
  end

  test "complete withdrawal resolves an expired adjacency finding", %{scope: scope} do
    local_resource = resource_fixture(scope, "neighbor-expiry-resolution-local")
    remote_resource = resource_fixture(scope, "neighbor-expiry-resolution-remote")
    {:ok, local} = Inventory.create_interface(scope, local_resource.id, %{name: "eth0"})
    {:ok, remote} = Inventory.create_interface(scope, remote_resource.id, %{name: "swp1"})

    {:ok, source} =
      Inventory.create_source(scope, %{
        kind: "manual",
        name: "neighbor-expiry-resolution",
        metadata: %{"interface_neighbor_snapshot_policy" => "complete"}
      })

    initial =
      observation_fixture(
        scope,
        source,
        "expiry-resolution-initial",
        ~U[2099-09-10 22:00:00Z],
        %{}
      )

    assert {:ok, [_]} =
             reconcile_neighbors(scope, source, initial, local_resource, [
               %{
                 "name" => local.name,
                 "neighbors" => [
                   neighbor(remote_resource.name, remote.name, %{"ttl_seconds" => 30})
                 ]
               }
             ])

    assert {:ok, []} =
             Topology.expire_interface_neighbors(scope, ~U[2099-09-10 22:01:00Z])

    assert Enum.any?(
             Topology.list_topology_findings(scope, local.id),
             &(&1.kind == "expired_adjacency")
           )

    complete =
      observation_fixture(
        scope,
        source,
        "expiry-resolution-complete",
        ~U[2099-09-10 22:02:00Z],
        %{
          "section_completeness" => %{"interface_neighbors" => true}
        }
      )

    assert {:ok, []} =
             reconcile_neighbors(scope, source, complete, local_resource, [
               %{"name" => local.name, "neighbors" => []}
             ])

    refute Enum.any?(
             Topology.list_topology_findings(scope, local.id),
             &(&1.kind == "expired_adjacency")
           )
  end

  test "successive already expired reports preserve one finding lifecycle", %{scope: scope} do
    local_resource = resource_fixture(scope, "neighbor-expiry-lifecycle-local")
    remote_resource = resource_fixture(scope, "neighbor-expiry-lifecycle-remote")
    {:ok, local} = Inventory.create_interface(scope, local_resource.id, %{name: "eth0"})
    {:ok, remote} = Inventory.create_interface(scope, remote_resource.id, %{name: "swp1"})
    {:ok, source} = Inventory.create_source(scope, %{kind: "manual", name: "expiry-lifecycle"})
    as_of = Renga.Time.utc_now_ms()

    first =
      observation_fixture(
        scope,
        source,
        "expiry-lifecycle-first",
        DateTime.add(as_of, -120, :second),
        %{}
      )

    assert {:ok, [_first_evidence]} =
             reconcile_neighbors(scope, source, first, local_resource, [
               %{
                 "name" => local.name,
                 "neighbors" => [
                   neighbor(remote_resource.name, remote.name, %{"ttl_seconds" => 60})
                 ]
               }
             ])

    assert [%{id: finding_id}] = Topology.list_topology_findings(scope, local.id)

    second =
      observation_fixture(
        scope,
        source,
        "expiry-lifecycle-second",
        DateTime.add(as_of, -90, :second),
        %{}
      )

    assert {:ok, [second_evidence]} =
             reconcile_neighbors(scope, source, second, local_resource, [
               %{
                 "name" => local.name,
                 "neighbors" => [
                   neighbor(remote_resource.name, remote.name, %{"ttl_seconds" => 60})
                 ]
               }
             ])

    assert [%{id: ^finding_id, details: %{"evidence_id" => evidence_id}}] =
             Topology.list_topology_findings(scope, local.id)

    assert evidence_id == second_evidence.id
    assert Topology.list_topology_findings(scope, local.id, "resolved") == []
  end

  test "stable chassis identity takes precedence over a conflicting system name", %{scope: scope} do
    local_resource = resource_fixture(scope, "neighbor-chassis-precedence-local")
    stable_resource = resource_fixture(scope, "neighbor-chassis-precedence-stable")
    misleading_resource = resource_fixture(scope, "neighbor-chassis-precedence-misleading")
    {:ok, local} = Inventory.create_interface(scope, local_resource.id, %{name: "eth0"})
    {:ok, stable_port} = Inventory.create_interface(scope, stable_resource.id, %{name: "swp1"})

    {:ok, _misleading_port} =
      Inventory.create_interface(scope, misleading_resource.id, %{name: "swp1"})

    assert {:ok, _identifier} =
             Inventory.create_resource_identifier(scope, stable_resource.id, %{
               kind: "external_id",
               value: "stable-chassis-id"
             })

    {:ok, source} = Inventory.create_source(scope, %{kind: "manual", name: "chassis-precedence"})

    observation =
      observation_fixture(scope, source, "chassis-precedence", ~U[2099-09-10 23:00:00Z], %{})

    assert {:ok, [evidence]} =
             reconcile_neighbors(scope, source, observation, local_resource, [
               %{
                 "name" => local.name,
                 "neighbors" => [
                   neighbor("stable-chassis-id", stable_port.name, %{
                     "remote_system_name" => misleading_resource.name
                   })
                 ]
               }
             ])

    assert %{status: "matched", remote_interface_id: remote_id} =
             Topology.get_interface_neighbor_match(scope, evidence.id)

    assert remote_id == stable_port.id
  end

  test "current host identity excludes historical hostname owners", %{scope: scope} do
    local_resource = resource_fixture(scope, "neighbor-current-host-local")
    former_resource = resource_fixture(scope, "neighbor-current-host-former")
    current_resource = resource_fixture(scope, "neighbor-current-host-current")
    {:ok, local} = Inventory.create_interface(scope, local_resource.id, %{name: "eth0"})
    {:ok, _former_port} = Inventory.create_interface(scope, former_resource.id, %{name: "swp1"})
    {:ok, current_port} = Inventory.create_interface(scope, current_resource.id, %{name: "swp1"})

    assert {:ok, former_host} =
             Inventory.create_host(scope, former_resource.id, %{hostname: "reused.example"})

    assert {:ok, _historical_identifier} =
             Inventory.create_resource_identifier(scope, former_resource.id, %{
               kind: "hostname",
               value: "reused.example"
             })

    assert {:ok, _former_host} =
             former_host
             |> Host.changeset(%{hostname: "renamed.example"})
             |> Repo.update()

    assert {:ok, _current_host} =
             Inventory.create_host(scope, current_resource.id, %{hostname: "reused.example"})

    {:ok, source} = Inventory.create_source(scope, %{kind: "manual", name: "current-host"})

    observation =
      observation_fixture(scope, source, "current-host", ~U[2099-09-10 23:10:00Z], %{})

    assert {:ok, [evidence]} =
             reconcile_neighbors(scope, source, observation, local_resource, [
               %{"name" => local.name, "neighbors" => [neighbor("reused.example", "swp1")]}
             ])

    assert %{status: "matched", remote_interface_id: remote_id} =
             Topology.get_interface_neighbor_match(scope, evidence.id)

    assert remote_id == current_port.id
  end

  test "same-direction LLDP and CDP evidence does not imply reciprocity", %{scope: scope} do
    local_resource = resource_fixture(scope, "neighbor-protocol-local")
    remote_resource = resource_fixture(scope, "neighbor-protocol-remote")
    {:ok, local} = Inventory.create_interface(scope, local_resource.id, %{name: "eth0"})
    {:ok, remote} = Inventory.create_interface(scope, remote_resource.id, %{name: "swp1"})
    {:ok, source} = Inventory.create_source(scope, %{kind: "manual", name: "neighbor-protocol"})

    observation =
      observation_fixture(scope, source, "neighbor-protocol", ~U[2099-09-10 23:20:00Z], %{})

    assert {:ok, evidence} =
             reconcile_neighbors(scope, source, observation, local_resource, [
               %{
                 "name" => local.name,
                 "neighbors" => [
                   neighbor(remote_resource.name, remote.name, %{"protocol" => "cdp"}),
                   neighbor(remote_resource.name, remote.name)
                 ]
               }
             ])

    lldp_evidence = Enum.find(evidence, &(&1.protocol == "lldp"))

    assert [
             %{
               confidence: "reported",
               metadata: %{"protocols" => ["cdp", "lldp"]},
               primary_evidence_id: primary_evidence_id
             }
           ] = Topology.list_current_interface_adjacencies(scope)

    assert primary_evidence_id == lldp_evidence.id
  end

  test "creating a host directly invalidates resource-name fallback", %{scope: scope} do
    local_resource = resource_fixture(scope, "neighbor-direct-host-local")
    remote_resource = resource_fixture(scope, "neighbor-direct-host-remote")
    {:ok, local} = Inventory.create_interface(scope, local_resource.id, %{name: "eth0"})
    {:ok, remote} = Inventory.create_interface(scope, remote_resource.id, %{name: "swp1"})
    {:ok, source} = Inventory.create_source(scope, %{kind: "manual", name: "direct-host"})

    observation =
      observation_fixture(scope, source, "direct-host", ~U[2099-09-10 23:21:00Z], %{})

    assert {:ok, [evidence]} =
             reconcile_neighbors(scope, source, observation, local_resource, [
               %{
                 "name" => local.name,
                 "neighbors" => [neighbor(remote_resource.name, remote.name)]
               }
             ])

    assert %{status: "matched"} = Topology.get_interface_neighbor_match(scope, evidence.id)
    assert [_adjacency] = Topology.list_current_interface_adjacencies(scope)

    assert {:ok, _host} =
             Inventory.create_host(scope, remote_resource.id, %{hostname: "different.example"})

    assert %{status: "unresolved"} = Topology.get_interface_neighbor_match(scope, evidence.id)
    assert Topology.list_current_interface_adjacencies(scope) == []
  end

  test "creating an interface directly can make a stable match ambiguous", %{scope: scope} do
    local_resource = resource_fixture(scope, "neighbor-direct-interface-local")
    first_remote = resource_fixture(scope, "neighbor-direct-interface-first")
    second_remote = resource_fixture(scope, "neighbor-direct-interface-second")
    remote_mac = "02:00:00:00:03:01"
    {:ok, local} = Inventory.create_interface(scope, local_resource.id, %{name: "eth0"})

    {:ok, first_port} =
      Inventory.create_interface(scope, first_remote.id, %{
        name: "swp1",
        mac_address: remote_mac
      })

    {:ok, source} = Inventory.create_source(scope, %{kind: "manual", name: "direct-interface"})

    observation =
      observation_fixture(scope, source, "direct-interface", ~U[2099-09-10 23:22:00Z], %{})

    assert {:ok, [evidence]} =
             reconcile_neighbors(scope, source, observation, local_resource, [
               %{
                 "name" => local.name,
                 "neighbors" => [
                   neighbor(remote_mac, first_port.name, %{
                     "remote_chassis_id_kind" => "mac_address",
                     "remote_port_id_kind" => "name"
                   })
                 ]
               }
             ])

    assert %{status: "matched", candidate_count: 1} =
             Topology.get_interface_neighbor_match(scope, evidence.id)

    assert {:ok, _second_port} =
             Inventory.create_interface(scope, second_remote.id, %{
               name: "swp1",
               mac_address: remote_mac
             })

    assert %{status: "ambiguous", candidate_count: 2} =
             Topology.get_interface_neighbor_match(scope, evidence.id)

    assert Topology.list_current_interface_adjacencies(scope) == []
  end

  test "creating a resource identifier directly can make a stable match ambiguous", %{
    scope: scope
  } do
    local_resource = resource_fixture(scope, "neighbor-direct-identifier-local")
    first_remote = resource_fixture(scope, "neighbor-direct-identifier-first")
    second_remote = resource_fixture(scope, "neighbor-direct-identifier-second")
    {:ok, local} = Inventory.create_interface(scope, local_resource.id, %{name: "eth0"})
    {:ok, _first_port} = Inventory.create_interface(scope, first_remote.id, %{name: "swp1"})
    {:ok, _second_port} = Inventory.create_interface(scope, second_remote.id, %{name: "swp1"})

    assert {:ok, _identifier} =
             Inventory.create_resource_identifier(scope, first_remote.id, %{
               kind: "external_id",
               value: "direct-shared-id"
             })

    {:ok, source} = Inventory.create_source(scope, %{kind: "manual", name: "direct-identifier"})

    observation =
      observation_fixture(scope, source, "direct-identifier", ~U[2099-09-10 23:23:00Z], %{})

    assert {:ok, [evidence]} =
             reconcile_neighbors(scope, source, observation, local_resource, [
               %{
                 "name" => local.name,
                 "neighbors" => [
                   neighbor("direct-shared-id", "swp1", %{
                     "remote_chassis_id_kind" => "local",
                     "remote_port_id_kind" => "name"
                   })
                 ]
               }
             ])

    assert %{status: "matched", candidate_count: 1} =
             Topology.get_interface_neighbor_match(scope, evidence.id)

    assert {:ok, _identifier} =
             Inventory.create_resource_identifier(scope, second_remote.id, %{
               kind: "external_id",
               value: "direct-shared-id"
             })

    assert %{status: "ambiguous", candidate_count: 2} =
             Topology.get_interface_neighbor_match(scope, evidence.id)

    assert Topology.list_current_interface_adjacencies(scope) == []
  end

  test "updating a resource directly invalidates resource-name fallback", %{scope: scope} do
    local_resource = resource_fixture(scope, "neighbor-direct-resource-local")
    remote_resource = resource_fixture(scope, "neighbor-direct-resource-remote")
    {:ok, local} = Inventory.create_interface(scope, local_resource.id, %{name: "eth0"})
    {:ok, remote} = Inventory.create_interface(scope, remote_resource.id, %{name: "swp1"})
    {:ok, source} = Inventory.create_source(scope, %{kind: "manual", name: "direct-resource"})

    observation =
      observation_fixture(scope, source, "direct-resource", ~U[2099-09-10 23:24:00Z], %{})

    assert {:ok, [evidence]} =
             reconcile_neighbors(scope, source, observation, local_resource, [
               %{
                 "name" => local.name,
                 "neighbors" => [neighbor(remote_resource.name, remote.name)]
               }
             ])

    assert %{status: "matched"} = Topology.get_interface_neighbor_match(scope, evidence.id)
    assert [_adjacency] = Topology.list_current_interface_adjacencies(scope)

    assert {:ok, _updated_resource} =
             Inventory.update_resource(scope, remote_resource, %{
               name: "neighbor-direct-resource-renamed"
             })

    assert %{status: "unresolved"} = Topology.get_interface_neighbor_match(scope, evidence.id)
    assert Topology.list_current_interface_adjacencies(scope) == []
  end

  test "neighbor matching and reads remain organization scoped", %{scope: scope} do
    local_resource = resource_fixture(scope, "neighbor-tenant-local")
    {:ok, local} = Inventory.create_interface(scope, local_resource.id, %{name: "eth0"})

    foreign_user = user_fixture()
    foreign_organization = organization_fixture()
    organization_membership_fixture(foreign_user, foreign_organization, %{role: "admin"})
    foreign_scope = Accounts.scope_for_user(foreign_user, foreign_organization.id)
    foreign_resource = resource_fixture(foreign_scope, "neighbor-tenant-remote")

    {:ok, foreign_port} =
      Inventory.create_interface(foreign_scope, foreign_resource.id, %{name: "swp1"})

    {:ok, source} = Inventory.create_source(scope, %{kind: "manual", name: "neighbor-tenant"})

    observation =
      observation_fixture(scope, source, "neighbor-tenant", ~U[2099-09-10 23:30:00Z], %{})

    assert {:ok, [evidence]} =
             reconcile_neighbors(scope, source, observation, local_resource, [
               %{
                 "name" => local.name,
                 "neighbors" => [neighbor(foreign_resource.name, foreign_port.name)]
               }
             ])

    assert %{status: "unresolved"} = Topology.get_interface_neighbor_match(scope, evidence.id)
    assert Topology.get_interface_neighbor_match(foreign_scope, evidence.id) == nil
    assert Topology.list_interface_neighbor_evidence(foreign_scope, local.id) == []

    local_remote_resource = resource_fixture(scope, "neighbor-tenant-local-remote")

    {:ok, local_remote} =
      Inventory.create_interface(scope, local_remote_resource.id, %{name: "swp1"})

    local_adjacency_observation =
      observation_fixture(
        scope,
        source,
        "neighbor-tenant-local-adjacency",
        ~U[2099-09-10 23:31:00Z],
        %{}
      )

    assert {:ok, [_evidence]} =
             reconcile_neighbors(scope, source, local_adjacency_observation, local_resource, [
               %{
                 "name" => local.name,
                 "neighbors" => [neighbor(local_remote_resource.name, local_remote.name)]
               }
             ])

    foreign_local_resource = resource_fixture(foreign_scope, "neighbor-tenant-foreign-local")

    {:ok, foreign_local} =
      Inventory.create_interface(foreign_scope, foreign_local_resource.id, %{name: "eth0"})

    {:ok, foreign_source} =
      Inventory.create_source(foreign_scope, %{kind: "manual", name: "neighbor-tenant-foreign"})

    foreign_observation =
      observation_fixture(
        foreign_scope,
        foreign_source,
        "neighbor-tenant-foreign-adjacency",
        ~U[2099-09-10 23:31:00Z],
        %{}
      )

    assert {:ok, [_evidence]} =
             reconcile_neighbors(
               foreign_scope,
               foreign_source,
               foreign_observation,
               foreign_local_resource,
               [
                 %{
                   "name" => foreign_local.name,
                   "neighbors" => [neighbor(foreign_resource.name, foreign_port.name)]
                 }
               ]
             )

    assert [local_adjacency] = Topology.list_current_interface_adjacencies(scope)
    assert local.id in [local_adjacency.interface_a_id, local_adjacency.interface_b_id]
    assert local_remote.id in [local_adjacency.interface_a_id, local_adjacency.interface_b_id]

    assert [foreign_adjacency] = Topology.list_current_interface_adjacencies(foreign_scope)

    assert foreign_local.id in [
             foreign_adjacency.interface_a_id,
             foreign_adjacency.interface_b_id
           ]

    assert foreign_port.id in [
             foreign_adjacency.interface_a_id,
             foreign_adjacency.interface_b_id
           ]
  end

  test "equivalent MAC spellings share evidence ordering identity", %{scope: scope} do
    local_resource = resource_fixture(scope, "neighbor-normalized-order-local")
    remote_resource = resource_fixture(scope, "neighbor-normalized-order-remote")
    {:ok, local} = Inventory.create_interface(scope, local_resource.id, %{name: "eth0"})

    {:ok, _remote} =
      Inventory.create_interface(scope, remote_resource.id, %{
        name: "swp1",
        mac_address: "02:00:00:00:00:02"
      })

    {:ok, source} = Inventory.create_source(scope, %{kind: "manual", name: "normalized-order"})

    newer =
      observation_fixture(scope, source, "normalized-newer", ~U[2099-09-11 00:01:00Z], %{})

    assert {:ok, [_newer]} =
             reconcile_neighbors(scope, source, newer, local_resource, [
               %{
                 "name" => local.name,
                 "neighbors" => [
                   neighbor(remote_resource.name, "02:00:00:00:00:02", %{
                     "remote_chassis_id_kind" => "name",
                     "remote_port_id_kind" => "mac_address",
                     "ttl_seconds" => 30
                   })
                 ]
               }
             ])

    assert {:ok, []} =
             Topology.expire_interface_neighbors(scope, ~U[2099-09-11 00:02:00Z])

    older =
      observation_fixture(scope, source, "normalized-older", ~U[2099-09-11 00:00:00Z], %{})

    assert {:ok, [delayed]} =
             reconcile_neighbors(
               scope,
               source,
               older,
               local_resource,
               [
                 %{
                   "name" => local.name,
                   "neighbors" => [
                     neighbor(remote_resource.name, "02-00-00-00-00-02", %{
                       "remote_chassis_id_kind" => "name",
                       "remote_port_id_kind" => "mac_address",
                       "ttl_seconds" => 600
                     })
                   ]
                 }
               ],
               false
             )

    assert Repo.reload!(delayed).stale_reason == "superseded"
    assert Topology.list_current_interface_adjacencies(scope) == []
  end

  test "untyped MAC spellings do not collide with opaque identifier namespaces", %{scope: scope} do
    local_resource = resource_fixture(scope, "neighbor-inferred-mac-local")
    mac_resource = resource_fixture(scope, "neighbor-inferred-mac-interface")
    opaque_resource = resource_fixture(scope, "neighbor-inferred-mac-opaque")
    {:ok, local} = Inventory.create_interface(scope, local_resource.id, %{name: "eth0"})

    {:ok, mac_port} =
      Inventory.create_interface(scope, mac_resource.id, %{
        name: "swp1",
        mac_address: "02:00:00:00:00:02"
      })

    {:ok, _opaque_port} = Inventory.create_interface(scope, opaque_resource.id, %{name: "swp1"})

    assert {:ok, _identifier} =
             Inventory.create_resource_identifier(scope, opaque_resource.id, %{
               kind: "external_id",
               value: "020000000002"
             })

    {:ok, source} = Inventory.create_source(scope, %{kind: "manual", name: "inferred-mac"})

    evidence =
      ["02:00:00:00:00:02", "020000000002", "0200.0000.0002"]
      |> Enum.with_index()
      |> Enum.map(fn {chassis_id, index} ->
        observation =
          observation_fixture(
            scope,
            source,
            "inferred-mac-#{index}",
            DateTime.add(~U[2099-09-11 00:03:00Z], index, :second),
            %{}
          )

        assert {:ok, [item]} =
                 reconcile_neighbors(
                   scope,
                   source,
                   observation,
                   local_resource,
                   [
                     %{
                       "name" => local.name,
                       "neighbors" => [
                         neighbor(chassis_id, mac_port.name, %{
                           "remote_port_id_kind" => "name"
                         })
                       ]
                     }
                   ],
                   false
                 )

        assert %{status: "matched", remote_interface_id: remote_id} =
                 Topology.get_interface_neighbor_match(scope, item.id)

        assert remote_id == mac_port.id
        assert [adjacency] = Topology.list_current_interface_adjacencies(scope)
        assert mac_port.id in [adjacency.interface_a_id, adjacency.interface_b_id]
        item
      end)

    assert evidence |> Enum.map(& &1.remote_chassis_id_normalized) |> Enum.uniq() == [
             "02:00:00:00:00:02"
           ]
  end

  test "untyped MAC chassis spellings are not resource name hints", %{scope: scope} do
    local_resource = resource_fixture(scope, "neighbor-mac-name-chassis-local")
    named_resource = resource_fixture(scope, "020000000003")
    {:ok, local} = Inventory.create_interface(scope, local_resource.id, %{name: "eth0"})
    {:ok, _named_port} = Inventory.create_interface(scope, named_resource.id, %{name: "swp1"})
    {:ok, source} = Inventory.create_source(scope, %{kind: "manual", name: "mac-name-chassis"})

    for {chassis_id, index} <-
          Enum.with_index(["02:00:00:00:00:03", "020000000003", "0200.0000.0003"]) do
      observation =
        observation_fixture(
          scope,
          source,
          "mac-name-chassis-#{index}",
          DateTime.add(~U[2099-09-11 00:04:00Z], index, :second),
          %{}
        )

      assert {:ok, [evidence]} =
               reconcile_neighbors(
                 scope,
                 source,
                 observation,
                 local_resource,
                 [
                   %{
                     "name" => local.name,
                     "neighbors" => [
                       neighbor(chassis_id, "swp1", %{"remote_port_id_kind" => "name"})
                     ]
                   }
                 ],
                 false
               )

      assert %{status: "unresolved", candidate_count: 0} =
               Topology.get_interface_neighbor_match(scope, evidence.id)

      assert Topology.list_current_interface_adjacencies(scope) == []
    end
  end

  test "untyped MAC port spellings are not interface name hints", %{scope: scope} do
    local_resource = resource_fixture(scope, "neighbor-mac-name-port-local")
    remote_resource = resource_fixture(scope, "neighbor-mac-name-port-remote")
    {:ok, local} = Inventory.create_interface(scope, local_resource.id, %{name: "eth0"})

    {:ok, _named_port} =
      Inventory.create_interface(scope, remote_resource.id, %{name: "020000000004"})

    {:ok, source} = Inventory.create_source(scope, %{kind: "manual", name: "mac-name-port"})

    for {port_id, index} <-
          Enum.with_index(["02:00:00:00:00:04", "020000000004", "0200.0000.0004"]) do
      observation =
        observation_fixture(
          scope,
          source,
          "mac-name-port-#{index}",
          DateTime.add(~U[2099-09-11 00:05:00Z], index, :second),
          %{}
        )

      assert {:ok, [evidence]} =
               reconcile_neighbors(
                 scope,
                 source,
                 observation,
                 local_resource,
                 [
                   %{
                     "name" => local.name,
                     "neighbors" => [
                       neighbor(remote_resource.name, port_id, %{
                         "remote_chassis_id_kind" => "name"
                       })
                     ]
                   }
                 ],
                 false
               )

      assert %{status: "unresolved", candidate_count: 0} =
               Topology.get_interface_neighbor_match(scope, evidence.id)

      assert Topology.list_current_interface_adjacencies(scope) == []
    end
  end

  test "contradictory stable chassis and port identities remain unresolved", %{scope: scope} do
    local_resource = resource_fixture(scope, "neighbor-contradiction-local")
    chassis_resource = resource_fixture(scope, "neighbor-contradiction-chassis")
    port_resource = resource_fixture(scope, "neighbor-contradiction-port")
    {:ok, local} = Inventory.create_interface(scope, local_resource.id, %{name: "eth0"})
    {:ok, _chassis_port} = Inventory.create_interface(scope, chassis_resource.id, %{name: "swp1"})

    {:ok, _other_port} =
      Inventory.create_interface(scope, port_resource.id, %{
        name: "swp2",
        mac_address: "02:00:00:00:10:02"
      })

    assert {:ok, _identifier} =
             Inventory.create_resource_identifier(scope, chassis_resource.id, %{
               kind: "external_id",
               value: "stable-chassis-b"
             })

    {:ok, source} = Inventory.create_source(scope, %{kind: "manual", name: "contradiction"})

    observation =
      observation_fixture(scope, source, "contradiction", ~U[2099-09-11 01:00:00Z], %{})

    assert {:ok, [evidence]} =
             reconcile_neighbors(scope, source, observation, local_resource, [
               %{
                 "name" => local.name,
                 "neighbors" => [
                   neighbor("stable-chassis-b", "02:00:00:00:10:02", %{
                     "remote_port_id_kind" => "mac_address",
                     "remote_port_description" => "swp1"
                   })
                 ]
               }
             ])

    assert %{status: "unresolved"} = Topology.get_interface_neighbor_match(scope, evidence.id)
    assert Topology.list_current_interface_adjacencies(scope) == []
  end

  test "opaque port identifiers use name fallback instead of embedded MAC text", %{scope: scope} do
    local_resource = resource_fixture(scope, "neighbor-opaque-local")
    named_resource = resource_fixture(scope, "neighbor-opaque-named")
    mac_resource = resource_fixture(scope, "neighbor-opaque-mac")
    {:ok, local} = Inventory.create_interface(scope, local_resource.id, %{name: "eth0"})
    {:ok, named_port} = Inventory.create_interface(scope, named_resource.id, %{name: "swp1"})

    {:ok, _mac_port} =
      Inventory.create_interface(scope, mac_resource.id, %{
        name: "swp2",
        mac_address: "02:00:00:00:00:02"
      })

    {:ok, source} = Inventory.create_source(scope, %{kind: "manual", name: "opaque-port"})
    observation = observation_fixture(scope, source, "opaque-port", ~U[2099-09-11 02:00:00Z], %{})

    assert {:ok, [evidence]} =
             reconcile_neighbors(scope, source, observation, local_resource, [
               %{
                 "name" => local.name,
                 "neighbors" => [
                   neighbor(named_resource.name, "port-020000000002", %{
                     "remote_chassis_id_kind" => "name",
                     "remote_port_description" => named_port.name
                   })
                 ]
               }
             ])

    assert %{status: "matched", strategy: "name_fallback", remote_interface_id: remote_id} =
             Topology.get_interface_neighbor_match(scope, evidence.id)

    assert remote_id == named_port.id
  end

  test "identity and presence overrides immediately refresh current adjacency", %{scope: scope} do
    local_resource = resource_fixture(scope, "neighbor-override-local")
    remote_resource = resource_fixture(scope, "neighbor-override-remote")
    {:ok, local} = Inventory.create_interface(scope, local_resource.id, %{name: "eth0"})

    {:ok, remote} =
      Inventory.create_interface(scope, remote_resource.id, %{
        name: "swp1",
        mac_address: "02:00:00:00:20:01"
      })

    {:ok, source} = Inventory.create_source(scope, %{kind: "manual", name: "neighbor-override"})

    observation =
      observation_fixture(scope, source, "neighbor-override", ~U[2099-09-11 03:00:00Z], %{})

    assert {:ok, [evidence]} =
             reconcile_neighbors(scope, source, observation, local_resource, [
               %{
                 "name" => local.name,
                 "neighbors" => [
                   neighbor("switch-override.example", "02:00:00:00:20:02", %{
                     "remote_port_id_kind" => "mac_address",
                     "remote_port_description" => remote.name
                   })
                 ]
               }
             ])

    assert %{status: "unresolved"} = Topology.get_interface_neighbor_match(scope, evidence.id)

    assert {:ok, _override} =
             Inventory.create_resource_override(scope, remote_resource.id, %{
               field: "host.hostname",
               value: %{"value" => "switch-override.example"}
             })

    assert %{status: "unresolved"} = Topology.get_interface_neighbor_match(scope, evidence.id)
    assert Topology.list_current_interface_adjacencies(scope) == []

    assert {:ok, _override} =
             Inventory.create_resource_override(scope, remote_resource.id, %{
               field: "interfaces.swp1.mac_address",
               value: %{"value" => "02:00:00:00:20:02"}
             })

    assert %{status: "matched", remote_interface_id: remote_id} =
             Topology.get_interface_neighbor_match(scope, evidence.id)

    assert remote_id == remote.id
    assert [_adjacency] = Topology.list_current_interface_adjacencies(scope)

    assert {:ok, _override} =
             Inventory.create_resource_override(scope, remote_resource.id, %{
               field: "interfaces.swp1.status",
               value: %{"value" => "not_present"}
             })

    assert Topology.list_current_interface_adjacencies(scope) == []
  end

  test "non-identity overrides refresh when they create matching candidates", %{scope: scope} do
    local_resource = resource_fixture(scope, "neighbor-override-create-local")
    remote_resource = resource_fixture(scope, "neighbor-override-create-remote")
    {:ok, local} = Inventory.create_interface(scope, local_resource.id, %{name: "eth0"})
    {:ok, source} = Inventory.create_source(scope, %{kind: "manual", name: "override-create"})

    observation =
      observation_fixture(scope, source, "override-create", ~U[2099-09-11 03:30:00Z], %{})

    assert {:ok, [evidence]} =
             reconcile_neighbors(scope, source, observation, local_resource, [
               %{
                 "name" => local.name,
                 "neighbors" => [neighbor(remote_resource.name, "swp1")]
               }
             ])

    assert %{status: "unresolved"} = Topology.get_interface_neighbor_match(scope, evidence.id)

    assert {:ok, _override} =
             Inventory.create_resource_override(scope, remote_resource.id, %{
               field: "interfaces.swp1.mtu",
               value: %{"value" => 1500}
             })

    [remote] = Inventory.list_interfaces(scope, remote_resource.id)

    assert %{status: "matched", remote_interface_id: remote_id} =
             Topology.get_interface_neighbor_match(scope, evidence.id)

    assert remote_id == remote.id
  end

  test "host-row creation refreshes resource-name fallback eligibility", %{scope: scope} do
    local_resource = resource_fixture(scope, "neighbor-host-create-local")
    remote_resource = resource_fixture(scope, "neighbor-host-create-remote")
    {:ok, local} = Inventory.create_interface(scope, local_resource.id, %{name: "eth0"})
    {:ok, remote} = Inventory.create_interface(scope, remote_resource.id, %{name: "swp1"})
    {:ok, source} = Inventory.create_source(scope, %{kind: "manual", name: "host-create"})
    observation = observation_fixture(scope, source, "host-create", ~U[2099-09-11 03:45:00Z], %{})

    assert {:ok, [evidence]} =
             reconcile_neighbors(scope, source, observation, local_resource, [
               %{
                 "name" => local.name,
                 "neighbors" => [neighbor(remote_resource.name, remote.name)]
               }
             ])

    assert %{status: "matched"} = Topology.get_interface_neighbor_match(scope, evidence.id)

    assert {:ok, _override} =
             Inventory.create_resource_override(scope, remote_resource.id, %{
               field: "host.vendor",
               value: %{"value" => "Example Vendor"}
             })

    assert %{status: "unresolved"} = Topology.get_interface_neighbor_match(scope, evidence.id)
    assert Topology.list_current_interface_adjacencies(scope) == []
  end

  test "neighbor findings use reconciliation time rather than agent observation time", %{
    scope: scope
  } do
    local_resource = resource_fixture(scope, "neighbor-finding-clock-local")
    {:ok, local} = Inventory.create_interface(scope, local_resource.id, %{name: "eth0"})
    {:ok, source} = Inventory.create_source(scope, %{kind: "manual", name: "finding-clock"})
    future = ~U[2199-09-11 04:00:00Z]
    before_reconcile = Renga.Time.utc_now_ms()
    observation = observation_fixture(scope, source, "finding-clock", future, %{})

    assert {:ok, [_evidence]} =
             reconcile_neighbors(scope, source, observation, local_resource, [
               %{"name" => local.name, "neighbors" => [neighbor("missing", "missing")]}
             ])

    finding =
      Enum.find(
        Topology.list_topology_findings(scope, local.id),
        &(&1.kind == "ambiguous_remote_identity")
      )

    assert DateTime.compare(finding.last_observed_at, before_reconcile) in [:eq, :gt]
    assert DateTime.compare(finding.last_observed_at, future) == :lt
  end

  test "presence override resolves an expired-only neighbor finding", %{scope: scope} do
    local_resource = resource_fixture(scope, "neighbor-expired-override-local")
    remote_resource = resource_fixture(scope, "neighbor-expired-override-remote")
    {:ok, local} = Inventory.create_interface(scope, local_resource.id, %{name: "eth0"})
    {:ok, remote} = Inventory.create_interface(scope, remote_resource.id, %{name: "swp1"})
    {:ok, source} = Inventory.create_source(scope, %{kind: "manual", name: "expired-override"})

    observation =
      observation_fixture(scope, source, "expired-override", ~U[2099-09-11 04:30:00Z], %{})

    assert {:ok, [_evidence]} =
             reconcile_neighbors(scope, source, observation, local_resource, [
               %{
                 "name" => local.name,
                 "neighbors" => [
                   neighbor(remote_resource.name, remote.name, %{"ttl_seconds" => 30})
                 ]
               }
             ])

    assert {:ok, []} =
             Topology.expire_interface_neighbors(scope, ~U[2099-09-11 04:31:00Z])

    assert Enum.any?(
             Topology.list_topology_findings(scope, local.id),
             &(&1.kind == "expired_adjacency")
           )

    assert {:ok, _override} =
             Inventory.create_resource_override(scope, local_resource.id, %{
               field: "interfaces.eth0.status",
               value: %{"value" => "not_present"}
             })

    assert Topology.list_topology_findings(scope, local.id) == []
  end

  test "expiry sweep isolates tenant failures and a worker schedules repeated sweeps", %{
    scope: scope
  } do
    local_resource = resource_fixture(scope, "neighbor-worker-local")
    remote_resource = resource_fixture(scope, "neighbor-worker-remote")
    {:ok, local} = Inventory.create_interface(scope, local_resource.id, %{name: "eth0"})
    {:ok, remote} = Inventory.create_interface(scope, remote_resource.id, %{name: "swp1"})
    {:ok, source} = Inventory.create_source(scope, %{kind: "manual", name: "neighbor-worker"})

    observation =
      observation_fixture(scope, source, "neighbor-worker", ~U[2099-09-11 05:00:00Z], %{})

    assert {:ok, [_evidence]} =
             reconcile_neighbors(scope, source, observation, local_resource, [
               %{
                 "name" => local.name,
                 "neighbors" => [
                   neighbor(remote_resource.name, remote.name, %{"ttl_seconds" => 30})
                 ]
               }
             ])

    foreign_user = user_fixture()
    foreign_organization = organization_fixture()
    organization_membership_fixture(foreign_user, foreign_organization, %{role: "admin"})
    foreign_scope = Accounts.scope_for_user(foreign_user, foreign_organization.id)
    foreign_local_resource = resource_fixture(foreign_scope, "neighbor-worker-foreign-local")
    foreign_remote_resource = resource_fixture(foreign_scope, "neighbor-worker-foreign-remote")

    {:ok, foreign_local} =
      Inventory.create_interface(foreign_scope, foreign_local_resource.id, %{name: "eth0"})

    {:ok, foreign_remote} =
      Inventory.create_interface(foreign_scope, foreign_remote_resource.id, %{name: "swp1"})

    {:ok, foreign_source} =
      Inventory.create_source(foreign_scope, %{kind: "manual", name: "neighbor-worker-foreign"})

    foreign_observation =
      observation_fixture(
        foreign_scope,
        foreign_source,
        "neighbor-worker-foreign",
        ~U[2099-09-11 05:00:00Z],
        %{}
      )

    assert {:ok, [_evidence]} =
             reconcile_neighbors(
               foreign_scope,
               foreign_source,
               foreign_observation,
               foreign_local_resource,
               [
                 %{
                   "name" => foreign_local.name,
                   "neighbors" => [
                     neighbor(foreign_remote_resource.name, foreign_remote.name, %{
                       "ttl_seconds" => 30
                     })
                   ]
                 }
               ]
             )

    test_process = self()

    [failed_organization_id, successful_organization_id] =
      Enum.sort([scope.organization_id, foreign_scope.organization_id])

    assert [
             {:error, %RuntimeError{message: "injected expiry failure"}},
             {:ok, :continued}
           ] =
             NeighborExpiryWorker.sweep(
               ~U[2099-09-11 05:01:00Z],
               fn tenant_scope, _as_of ->
                 send(test_process, {:expired_tenant, tenant_scope.organization_id})

                 if tenant_scope.organization_id == failed_organization_id,
                   do: raise("injected expiry failure"),
                   else: {:ok, :continued}
               end
             )

    assert_receive {:expired_tenant, ^failed_organization_id}
    assert_receive {:expired_tenant, ^successful_organization_id}

    {:ok, worker} =
      NeighborExpiryWorker.start_link(
        name: nil,
        interval: 5,
        sweep: fn -> send(test_process, :scheduled_sweep) end
      )

    assert_receive :scheduled_sweep, 100
    assert_receive :scheduled_sweep, 100
    GenServer.stop(worker)
  end

  test "case-sensitive port names remain distinct evidence identities", %{scope: scope} do
    local_resource = resource_fixture(scope, "neighbor-port-case-local")
    remote_resource = resource_fixture(scope, "neighbor-port-case-remote")
    {:ok, local} = Inventory.create_interface(scope, local_resource.id, %{name: "uplink"})
    {:ok, lower_port} = Inventory.create_interface(scope, remote_resource.id, %{name: "eth0"})
    {:ok, upper_port} = Inventory.create_interface(scope, remote_resource.id, %{name: "ETH0"})
    {:ok, source} = Inventory.create_source(scope, %{kind: "manual", name: "neighbor-port-case"})

    observation =
      observation_fixture(scope, source, "neighbor-port-case", ~U[2099-09-11 07:00:00Z], %{})

    assert {:ok, evidence} =
             reconcile_neighbors(scope, source, observation, local_resource, [
               %{
                 "name" => local.name,
                 "neighbors" => [
                   neighbor(remote_resource.name, lower_port.name, %{
                     "remote_chassis_id_kind" => "name",
                     "remote_port_id_kind" => "name"
                   }),
                   neighbor(remote_resource.name, upper_port.name, %{
                     "remote_chassis_id_kind" => "name",
                     "remote_port_id_kind" => "name"
                   })
                 ]
               }
             ])

    assert length(evidence) == 2

    assert evidence
           |> Enum.map(&Topology.get_interface_neighbor_match(scope, &1.id).remote_interface_id)
           |> Enum.sort() == Enum.sort([lower_port.id, upper_port.id])
  end

  test "equivalent IPv6 chassis addresses match and share ordering identity", %{scope: scope} do
    assert NeighborIdentifier.normalize_chassis("network_address", "192.0.2.1") ==
             NeighborIdentifier.normalize_chassis("network_address", "192.0.2.1/32")

    local_resource = resource_fixture(scope, "neighbor-ipv6-local")
    remote_resource = resource_fixture(scope, "neighbor-ipv6-remote")
    {:ok, local} = Inventory.create_interface(scope, local_resource.id, %{name: "eth0"})
    {:ok, remote} = Inventory.create_interface(scope, remote_resource.id, %{name: "swp1"})

    assert {:ok, _identifier} =
             Inventory.create_resource_identifier(scope, remote_resource.id, %{
               kind: "bmc_address",
               value: "2001:db8::1"
             })

    {:ok, source} = Inventory.create_source(scope, %{kind: "manual", name: "neighbor-ipv6"})
    newer = observation_fixture(scope, source, "neighbor-ipv6-new", ~U[2099-09-11 08:01:00Z], %{})

    assert {:ok, [newer_evidence]} =
             reconcile_neighbors(scope, source, newer, local_resource, [
               %{
                 "name" => local.name,
                 "neighbors" => [
                   neighbor("2001:0db8:0:0:0:0:0:1", remote.name, %{
                     "remote_chassis_id_kind" => "network_address",
                     "ttl_seconds" => 30
                   })
                 ]
               }
             ])

    assert %{status: "matched", remote_interface_id: remote_id} =
             Topology.get_interface_neighbor_match(scope, newer_evidence.id)

    assert remote_id == remote.id
    assert {:ok, []} = Topology.expire_interface_neighbors(scope, ~U[2099-09-11 08:02:00Z])

    older = observation_fixture(scope, source, "neighbor-ipv6-old", ~U[2099-09-11 08:00:00Z], %{})

    assert {:ok, [delayed]} =
             reconcile_neighbors(
               scope,
               source,
               older,
               local_resource,
               [
                 %{
                   "name" => local.name,
                   "neighbors" => [
                     neighbor("2001:db8::1/128", remote.name, %{
                       "remote_chassis_id_kind" => "network_address",
                       "ttl_seconds" => 600
                     })
                   ]
                 }
               ],
               false
             )

    assert Repo.reload!(delayed).stale_reason == "superseded"
    assert Topology.list_current_interface_adjacencies(scope) == []
  end

  test "repeated unresolved evidence preserves one finding lifecycle", %{scope: scope} do
    local_resource = resource_fixture(scope, "neighbor-finding-identity-local")
    {:ok, local} = Inventory.create_interface(scope, local_resource.id, %{name: "eth0"})
    {:ok, source} = Inventory.create_source(scope, %{kind: "manual", name: "finding-identity"})

    first =
      observation_fixture(scope, source, "finding-identity-1", ~U[2099-09-11 09:00:00Z], %{})

    assert {:ok, [_evidence]} =
             reconcile_neighbors(scope, source, first, local_resource, [
               %{"name" => local.name, "neighbors" => [neighbor("missing", "missing")]}
             ])

    [first_finding] = Topology.list_topology_findings(scope, local.id)

    second =
      observation_fixture(scope, source, "finding-identity-2", ~U[2099-09-11 09:01:00Z], %{})

    assert {:ok, [latest_evidence]} =
             reconcile_neighbors(scope, source, second, local_resource, [
               %{"name" => local.name, "neighbors" => [neighbor("missing", "missing")]}
             ])

    assert [latest_finding] = Topology.list_topology_findings(scope, local.id)
    assert latest_finding.id == first_finding.id
    assert latest_finding.details["evidence_id"] == latest_evidence.id
    assert Topology.list_topology_findings(scope, local.id, "resolved") == []
  end

  test "complete snapshots distinguish retained supersession from omitted withdrawal", %{
    scope: scope
  } do
    local_resource = resource_fixture(scope, "neighbor-complete-reasons-local")
    first_remote = resource_fixture(scope, "neighbor-complete-reasons-first")
    second_remote = resource_fixture(scope, "neighbor-complete-reasons-second")
    {:ok, local} = Inventory.create_interface(scope, local_resource.id, %{name: "eth0"})
    {:ok, first_port} = Inventory.create_interface(scope, first_remote.id, %{name: "swp1"})
    {:ok, second_port} = Inventory.create_interface(scope, second_remote.id, %{name: "swp1"})

    {:ok, source} =
      Inventory.create_source(scope, %{
        kind: "manual",
        name: "complete-reasons",
        metadata: %{"interface_neighbor_snapshot_policy" => "complete"}
      })

    first =
      observation_fixture(scope, source, "complete-reasons-1", ~U[2099-09-11 10:00:00Z], %{
        "section_completeness" => %{"interface_neighbors" => true}
      })

    assert {:ok, [retained, omitted]} =
             reconcile_neighbors(scope, source, first, local_resource, [
               %{
                 "name" => local.name,
                 "neighbors" => [
                   neighbor(first_remote.name, first_port.name),
                   neighbor(second_remote.name, second_port.name)
                 ]
               }
             ])

    second =
      observation_fixture(scope, source, "complete-reasons-2", ~U[2099-09-11 10:01:00Z], %{
        "section_completeness" => %{"interface_neighbors" => true}
      })

    assert {:ok, [_latest]} =
             reconcile_neighbors(scope, source, second, local_resource, [
               %{
                 "name" => local.name,
                 "neighbors" => [neighbor(first_remote.name, first_port.name)]
               }
             ])

    assert Repo.reload!(retained).stale_reason == "superseded"
    assert Repo.reload!(omitted).stale_reason == "withdrawn"
  end

  test "skips neighbor reconciliation when an organization has no neighbor state", %{scope: scope} do
    resource = resource_fixture(scope, "neighbor-fast-path")

    source =
      elem(Inventory.create_source(scope, %{kind: "manual", name: "neighbor-fast-path"}), 1)

    observation =
      observation_fixture(scope, source, "neighbor-fast-path", ~U[2099-09-10 23:40:00Z], %{})

    refute Topology.interface_neighbor_reconciliation_needed?(
             scope,
             observation,
             resource.id,
             [%{"name" => "eth0"}]
           )
  end

  test "active neighbor state conservatively rematches after unrelated inventory", %{
    scope: scope
  } do
    local_resource = resource_fixture(scope, "neighbor-guard-local")
    remote_resource = resource_fixture(scope, "neighbor-guard-remote")
    unrelated_resource = resource_fixture(scope, "neighbor-guard-unrelated")
    {:ok, local} = Inventory.create_interface(scope, local_resource.id, %{name: "eth0"})
    {:ok, remote} = Inventory.create_interface(scope, remote_resource.id, %{name: "swp1"})
    {:ok, source} = Inventory.create_source(scope, %{kind: "manual", name: "neighbor-guard"})

    active_observation =
      observation_fixture(scope, source, "neighbor-guard-active", ~U[2099-09-11 11:00:00Z], %{})

    assert {:ok, [_evidence]} =
             reconcile_neighbors(scope, source, active_observation, local_resource, [
               %{
                 "name" => local.name,
                 "neighbors" => [neighbor(remote_resource.name, remote.name)]
               }
             ])

    unrelated_observation =
      observation_fixture(
        scope,
        source,
        "neighbor-guard-unrelated",
        ~U[2099-09-11 11:01:00Z],
        %{}
      )

    assert Topology.interface_neighbor_reconciliation_needed?(
             scope,
             unrelated_observation,
             unrelated_resource.id,
             []
           )
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

  test "links prefixes to VLANs in both directions without implying ownership", %{scope: scope} do
    {:ok, group} = vlan_group_fixture(scope, "prefix-links", [{1, 100}])
    {:ok, first_vlan} = vlan_fixture(scope, group, 10, "Servers")
    {:ok, second_vlan} = vlan_fixture(scope, group, 20, "Clients")
    first_prefix = prefix_fixture(scope, "prefix-links-a", "192.0.2.0/24")
    second_prefix = prefix_fixture(scope, "prefix-links-b", "198.51.100.0/24")

    # A prefix and a VLAN are valid without any link between them.
    assert Topology.list_prefix_vlans(scope, first_prefix.id) == []
    assert Topology.list_vlan_prefixes(scope, first_vlan.id) == []

    assert {:ok, first_relationship} =
             Topology.attach_prefix_vlan(scope, first_prefix.id, first_vlan.id)

    assert first_relationship.prefix_id == first_prefix.id
    assert first_relationship.vlan_id == first_vlan.id
    assert first_relationship.prefix.resource.display_name == "192.0.2.0/24"

    assert {:ok, _relationship} =
             Topology.attach_prefix_vlan(scope, second_prefix.id, first_vlan.id)

    assert {:ok, _relationship} =
             Topology.attach_prefix_vlan(scope, second_prefix.id, second_vlan.id)

    assert [%{vid: 10}, %{vid: 20}] = Topology.list_prefix_vlans(scope, second_prefix.id)

    assert first_vlan_prefixes = Topology.list_vlan_prefixes(scope, first_vlan.id)

    assert Enum.map(first_vlan_prefixes, & &1.resource.display_name) |> Enum.sort() == [
             "192.0.2.0/24",
             "198.51.100.0/24"
           ]

    assert [%Prefix{prefix: %Postgrex.INET{address: {198, 51, 100, 0}, netmask: 24}}] =
             Topology.list_vlan_prefixes(scope, second_vlan.id)

    assert Enum.count(Topology.list_prefix_vlan_relationships(scope)) == 3

    assert {:ok, _removed} = Topology.detach_prefix_vlan(scope, second_prefix.id, first_vlan.id)

    assert [%{vid: 20}] = Topology.list_prefix_vlans(scope, second_prefix.id)

    assert [%Prefix{prefix: %Postgrex.INET{address: {192, 0, 2, 0}, netmask: 24}}] =
             Topology.list_vlan_prefixes(scope, first_vlan.id)

    # Detaching an already-detached link stays harmless.
    assert {:error, :not_found} =
             Topology.detach_prefix_vlan(scope, second_prefix.id, first_vlan.id)
  end

  test "rejects duplicate prefix/VLAN links regardless of attach order", %{scope: scope} do
    {:ok, group} = vlan_group_fixture(scope, "duplicate-links", [{1, 100}])
    {:ok, vlan} = vlan_fixture(scope, group, 10, "Servers")
    prefix = prefix_fixture(scope, "duplicate-links-prefix", "192.0.2.0/24")

    assert {:ok, _relationship} = Topology.attach_prefix_vlan(scope, prefix.id, vlan.id)

    assert {:error, %Ecto.Changeset{} = changeset} =
             Topology.attach_prefix_vlan(scope, prefix.id, vlan.id)

    assert %{vlan_id: ["has already been taken"]} = errors_on(changeset)

    assert [%PrefixVlanRelationship{}] = Topology.list_prefix_vlan_relationships(scope)
  end

  test "prefix/VLAN links require an active manager and reject foreign endpoints", %{
    scope: scope,
    organization: organization
  } do
    {:ok, group} = vlan_group_fixture(scope, "link-authorization", [{1, 100}])
    {:ok, vlan} = vlan_fixture(scope, group, 10, "Authorized")
    prefix = prefix_fixture(scope, "link-authorization-prefix", "192.0.2.0/24")

    viewer = user_fixture()
    organization_membership_fixture(viewer, organization, %{role: "viewer"})
    viewer_scope = Accounts.scope_for_user(viewer, organization.id)

    assert {:error, :forbidden} = Topology.attach_prefix_vlan(viewer_scope, prefix.id, vlan.id)
    assert Topology.list_prefix_vlan_relationships(viewer_scope) == []
    assert {:error, :forbidden} = Topology.detach_prefix_vlan(viewer_scope, prefix.id, vlan.id)

    other_user = user_fixture()
    other_organization = organization_fixture()
    organization_membership_fixture(other_user, other_organization, %{role: "admin"})
    other_scope = Accounts.scope_for_user(other_user, other_organization.id)
    other_prefix = prefix_fixture(other_scope, "foreign-link-prefix", "192.0.2.0/24")
    {:ok, other_group} = vlan_group_fixture(other_scope, "foreign-link-group", [{1, 100}])
    {:ok, other_vlan} = vlan_fixture(other_scope, other_group, 10, "Foreign")

    assert_raise Ecto.NoResultsError, fn ->
      Topology.attach_prefix_vlan(scope, other_prefix.id, vlan.id)
    end

    assert_raise Ecto.NoResultsError, fn ->
      Topology.attach_prefix_vlan(scope, prefix.id, other_vlan.id)
    end

    assert Topology.list_prefix_vlan_relationships(other_scope) == []
  end

  test "database tenant foreign keys reject cross-organization prefix/VLAN links", %{scope: scope} do
    {:ok, group} = vlan_group_fixture(scope, "tenant-links", [{1, 100}])
    {:ok, vlan} = vlan_fixture(scope, group, 10, "Local")

    foreign_user = user_fixture()
    foreign_organization = organization_fixture()
    organization_membership_fixture(foreign_user, foreign_organization, %{role: "admin"})
    foreign_scope = Accounts.scope_for_user(foreign_user, foreign_organization.id)
    foreign_prefix = prefix_fixture(foreign_scope, "foreign-tenant-prefix", "192.0.2.0/24")
    {:ok, foreign_group} = vlan_group_fixture(foreign_scope, "foreign-tenant-group", [{1, 100}])
    {:ok, foreign_vlan} = vlan_fixture(foreign_scope, foreign_group, 10, "Foreign")

    assert {:error, changeset} =
             %PrefixVlanRelationship{
               organization_id: scope.organization_id,
               prefix_id: foreign_prefix.id,
               vlan_id: vlan.id
             }
             |> PrefixVlanRelationship.changeset(%{})
             |> Repo.insert()

    assert "does not exist" in errors_on(changeset).prefix

    # The mirrored case: a foreign VLAN endpoint is equally rejected.
    assert {:error, changeset} =
             %PrefixVlanRelationship{
               organization_id: scope.organization_id,
               prefix_id: prefix_fixture(scope, "local-tenant-prefix", "192.0.2.0/24").id,
               vlan_id: foreign_vlan.id
             }
             |> PrefixVlanRelationship.changeset(%{})
             |> Repo.insert()

    assert "does not exist" in errors_on(changeset).vlan

    assert Topology.list_prefix_vlan_relationships(scope) == []
  end

  test "removing either endpoint removes its prefix/VLAN links but never the other side", %{
    scope: scope
  } do
    {:ok, group} = vlan_group_fixture(scope, "link-cascades", [{1, 100}])
    {:ok, vlan} = vlan_fixture(scope, group, 10, "Servers")
    prefix = prefix_fixture(scope, "link-cascades-prefix", "192.0.2.0/24")

    assert {:ok, _relationship} = Topology.attach_prefix_vlan(scope, prefix.id, vlan.id)

    # Deleting a VLAN removes its links while the prefix keeps existing.
    Repo.delete!(vlan)

    assert Topology.list_prefix_vlan_relationships(scope) == []
    assert Topology.list_prefix_vlans(scope, prefix.id) == []
    assert Repo.reload(prefix)

    Repo.delete!(Inventory.get_resource!(scope, prefix.resource_id))

    assert_raise Ecto.NoResultsError, fn -> Repo.reload!(prefix) end
  end

  test "deleting the prefix first keeps the VLAN and drops only its links", %{scope: scope} do
    {:ok, group} = vlan_group_fixture(scope, "prefix-cascades", [{1, 100}])
    {:ok, vlan} = vlan_fixture(scope, group, 10, "Servers")
    prefix = prefix_fixture(scope, "prefix-cascades-prefix", "192.0.2.0/24")

    assert {:ok, _relationship} = Topology.attach_prefix_vlan(scope, prefix.id, vlan.id)

    Repo.delete!(prefix)

    assert Topology.list_prefix_vlan_relationships(scope) == []
    assert Topology.list_vlan_prefixes(scope, vlan.id) == []
    assert [%Vlan{}] = Topology.list_vlans(scope, group.id)
    assert Repo.reload(vlan)
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

    local_resource = resource_fixture(scope, "local-evidence-server")
    {:ok, local_interface} = Inventory.create_interface(scope, local_resource.id, %{name: "eth0"})

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

    own_evidence =
      %InterfaceNeighborEvidence{
        organization_id: scope.organization_id,
        local_interface_id: local_interface.id,
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
      |> Repo.insert!()

    match_changeset =
      %InterfaceNeighborMatch{
        organization_id: scope.organization_id,
        interface_neighbor_evidence_id: own_evidence.id
      }
      |> InterfaceNeighborMatch.changeset(%{
        status: "matched",
        strategy: "name_fallback",
        candidate_count: 1,
        remote_interface_id: foreign_interface.id
      })

    assert {:error, rejected_match} = Repo.insert(match_changeset)
    assert "does not exist" in errors_on(rejected_match).remote_interface

    [interface_a_id, interface_b_id] = Enum.sort([local_interface.id, foreign_interface.id])

    adjacency_changeset =
      %CurrentInterfaceAdjacency{
        organization_id: scope.organization_id,
        interface_a_id: interface_a_id,
        interface_b_id: interface_b_id,
        primary_evidence_id: own_evidence.id
      }
      |> CurrentInterfaceAdjacency.changeset(%{
        confidence: "reported",
        last_observed_at: observation.observed_at,
        metadata: %{}
      })

    assert {:error, rejected_adjacency} = Repo.insert(adjacency_changeset)
    adjacency_errors = errors_on(rejected_adjacency)

    assert "does not exist" in (Map.get(adjacency_errors, :interface_a, []) ++
                                  Map.get(adjacency_errors, :interface_b, []))

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

  test "database tenant foreign keys reject cross-organization VLAN rows", %{scope: scope} do
    local_resource = resource_fixture(scope, "local-vlan-rows-server")
    {:ok, local_group} = vlan_group_fixture(scope, "local-vlan-rows", [{1, 100}])

    foreign_user = user_fixture()
    foreign_organization = organization_fixture()
    organization_membership_fixture(foreign_user, foreign_organization, %{role: "admin"})
    foreign_scope = Accounts.scope_for_user(foreign_user, foreign_organization.id)
    {:ok, foreign_group} = vlan_group_fixture(foreign_scope, "foreign-vlan-rows", [{1, 100}])
    foreign_resource = resource_fixture(foreign_scope, "foreign-vlan-rows-server")

    foreign_group_changeset =
      %Vlan{
        organization_id: scope.organization_id,
        resource_id: local_resource.id,
        vlan_group_id: foreign_group.id
      }
      |> Vlan.changeset(%{vid: 10, name: "Cross-tenant group", status: "active", metadata: %{}})

    assert {:error, rejected_group} = Repo.insert(foreign_group_changeset)
    assert "does not exist" in errors_on(rejected_group).vlan_group

    foreign_resource_changeset =
      %Vlan{
        organization_id: scope.organization_id,
        resource_id: foreign_resource.id,
        vlan_group_id: local_group.id
      }
      |> Vlan.changeset(%{
        vid: 11,
        name: "Cross-tenant resource",
        status: "active",
        metadata: %{}
      })

    assert {:error, rejected_resource} = Repo.insert(foreign_resource_changeset)
    assert "does not exist" in errors_on(rejected_resource).resource
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

  test "asserts confirmed cabling with attribution, history, and one termination per endpoint", %{
    scope: scope
  } do
    first = interface_fixture(scope, "cable-primary", "eth0")
    second = interface_fixture(scope, "cable-secondary", "swp1")

    assert {:ok, assertion} =
             Topology.assert_cable(scope, %{
               interface_a_id: second.id,
               interface_b_id: first.id,
               cable_type: "cat6a",
               label: "uplink",
               color: "#336699",
               length_value: "1.5",
               length_unit: "m",
               description: "rack uplink"
             })

    assert assertion.kind == "operator"
    assert assertion.action == "assert"
    assert assertion.confirmation == "confirmed"
    assert assertion.actor_user_id == scope.user.id
    assert assertion.interface_a_id < assertion.interface_b_id

    assert [cable] = Topology.list_cables(scope)
    assert cable.cable_type == "cat6a"
    assert cable.status == "connected"
    assert cable.label == "uplink"
    assert cable.color == "#336699"
    assert Decimal.equal?(cable.length_value, Decimal.new("1.5"))
    assert cable.length_unit == "m"
    assert cable.description == "rack uplink"
    assert cable.primary_assertion_id == assertion.id
    assert cable.last_asserted_at == assertion.asserted_at

    assert [created] = Topology.list_cable_change_events(scope, cable.id)
    assert created.action == "created"
    assert created.cable_id == cable.id
    assert created.actor_user_id == scope.user.id
    assert created.changes == %{}

    assert %{rows: [[2]]} =
             Repo.query!(
               "SELECT count(*) FROM cable_endpoint_terminations WHERE cable_id = $1::text::uuid",
               [cable.id]
             )

    assert_raise Postgrex.Error, ~r/cable assertions are immutable/, fn ->
      Repo.update_all(
        from(item in CableAssertion, where: item.id == ^assertion.id),
        set: [action: "retract"]
      )
    end

    # retraction releases the endpoints but keeps attributed history, including
    # attributes that are stripped because a retraction carries no cable facts
    assert {:ok, retraction} =
             Topology.retract_cable(scope, %{
               interface_a_id: first.id,
               interface_b_id: second.id,
               cable_type: "cat6a"
             })

    assert retraction.action == "retract"
    assert is_nil(retraction.cable_type)

    assert Topology.list_cables(scope) == []

    # history keeps its cable identity after the projection is removed
    assert [created_event, removed_event] = Topology.list_cable_change_events(scope, cable.id)
    assert created_event.action == "created"
    assert removed_event.action == "removed"
    assert removed_event.cable_id == cable.id

    assert [created_event, removed_event] =
             Topology.list_interface_cable_change_events(scope, first.id)

    assert created_event.action == "created"
    assert created_event.interface_a_id == assertion.interface_a_id
    assert created_event.interface_b_id == assertion.interface_b_id
    assert removed_event.action == "removed"
    assert removed_event.interface_a_id == assertion.interface_a_id
  end

  test "keeps cable plans separate from current cabling and reports feasibility and drift", %{
    scope: scope
  } do
    first = interface_fixture(scope, "cable-plan-first", "eth0")
    second = interface_fixture(scope, "cable-plan-second", "swp1")
    third = interface_fixture(scope, "cable-plan-third", "swp2")

    assert {:ok, plan} =
             Topology.put_cable_plan(scope, %{
               interface_a_id: first.id,
               interface_b_id: third.id,
               cable_type: "dac",
               status: "planned",
               length_value: "2",
               length_unit: "m"
             })

    # a plan never reserves an endpoint
    assert Topology.list_cables(scope) == []
    assert Topology.list_topology_findings(scope, first.id) == []

    assert {:ok, _assertion} =
             Topology.assert_cable(scope, %{
               interface_a_id: first.id,
               interface_b_id: second.id,
               cable_type: "cat6a"
             })

    assert [cable] = Topology.list_cables(scope)

    assert [conflict] =
             Topology.list_topology_findings(scope, first.id)
             |> Enum.filter(&(&1.kind == "cable_plan_conflict"))

    assert conflict.details["plan_id"] == plan.id

    assert {:ok, _deleted} = Topology.delete_cable_plan(scope, plan)

    refute Enum.any?(
             Topology.list_topology_findings(scope, first.id),
             &(&1.kind == "cable_plan_conflict")
           )

    # an agreeing plan drifts only when its physical attributes differ
    assert {:ok, _drift_plan} =
             Topology.put_cable_plan(scope, %{
               interface_a_id: first.id,
               interface_b_id: second.id,
               cable_type: "cat5e",
               length_value: "9",
               length_unit: "m"
             })

    assert [drift] =
             findings_for(scope, [first.id, second.id])
             |> Enum.filter(&(&1.kind == "cable_plan_drift"))

    assert drift.details["interface_a_id"] == cable.interface_a_id
    assert drift.details["interface_b_id"] == cable.interface_b_id

    # an infeasible plan is reported, not silently cabled
    bridge = interface_fixture(scope, "cable-plan-bridge", "br0", %{kind: "bridge"})

    assert {:ok, _infeasible_plan} =
             Topology.put_cable_plan(scope, %{
               interface_a_id: bridge.id,
               interface_b_id: third.id,
               status: "planned"
             })

    assert Enum.any?(
             Topology.list_topology_findings(scope, bridge.id),
             &(&1.kind == "cable_plan_infeasible")
           )

    assert [plan_row] = Topology.list_cable_plans(scope, interface_id: bridge.id)
    assert plan_row.status == "planned"
    assert length(Topology.list_cables(scope)) == 1
  end

  test "newest confirmed assertion wins a contested endpoint and reports a conflict", %{
    scope: scope
  } do
    first = interface_fixture(scope, "cable-contest-first", "eth0")
    second = interface_fixture(scope, "cable-contest-second", "swp1")
    third = interface_fixture(scope, "cable-contest-third", "swp2")

    assert {:ok, _older} =
             Topology.assert_cable(scope, %{
               interface_a_id: first.id,
               interface_b_id: second.id,
               asserted_at: ~U[2026-09-16 10:00:00.000000Z]
             })

    assert {:ok, _newer} =
             Topology.assert_cable(scope, %{
               interface_a_id: first.id,
               interface_b_id: third.id,
               asserted_at: ~U[2026-09-16 11:00:00.000000Z]
             })

    assert [cable] = Topology.list_cables(scope)
    assert cable.interface_a_id == Enum.min([first.id, third.id])
    assert cable.interface_b_id == Enum.max([first.id, third.id])

    assert [conflict] =
             Topology.list_topology_findings(scope, first.id)
             |> Enum.filter(&(&1.kind == "cable_endpoint_conflict"))

    assert conflict.details["interface_a_id"] == Enum.min([first.id, second.id])
    assert conflict.details["interface_b_id"] == Enum.max([first.id, second.id])

    # the losing claim is retained as attributable history, not deleted
    assert length(Topology.list_cable_assertions(scope)) == 2

    assert %{rows: [[1]]} =
             Repo.query!(
               "SELECT count(*) FROM cable_endpoint_terminations WHERE organization_id = $1::text::uuid AND interface_id = $2::text::uuid",
               [scope.organization_id, first.id]
             )
  end

  test "requires distinct physical endpoints inside one organization", %{scope: scope} do
    first = interface_fixture(scope, "cable-endpoint-first", "eth0")
    bridge = interface_fixture(scope, "cable-endpoint-bridge", "br0", %{kind: "bridge"})

    assert {:error, :identical_cable_endpoints} =
             Topology.assert_cable(scope, %{
               interface_a_id: first.id,
               interface_b_id: first.id
             })

    assert {:error, :cable_endpoint_not_physical} =
             Topology.assert_cable(scope, %{
               interface_a_id: first.id,
               interface_b_id: bridge.id
             })

    assert {:error, :identical_cable_endpoints} =
             Topology.put_cable_plan(scope, %{
               interface_a_id: bridge.id,
               interface_b_id: bridge.id
             })

    # Unselected form controls submit empty strings, which must read as missing
    # endpoints rather than reach the database as UUIDs.
    assert {:error, :cable_endpoints_required} =
             Topology.put_cable_plan(scope, %{interface_a_id: "", interface_b_id: first.id})

    assert {:error, :cable_endpoints_required} =
             Topology.put_cable_plan(scope, %{
               "interface_a_id" => first.id,
               "interface_b_id" => ""
             })

    assert {:error, %Ecto.Changeset{} = changeset} =
             Topology.assert_cable(scope, %{interface_a_id: first.id})

    assert "can't be blank" in errors_on(changeset).interface_b_id

    foreign_user = user_fixture()
    foreign_organization = organization_fixture()
    organization_membership_fixture(foreign_user, foreign_organization, %{role: "admin"})
    foreign_scope = Accounts.scope_for_user(foreign_user, foreign_organization.id)
    foreign = interface_fixture(foreign_scope, "cable-endpoint-foreign", "eth0")

    assert_raise Ecto.NoResultsError, fn ->
      Topology.assert_cable(scope, %{interface_a_id: first.id, interface_b_id: foreign.id})
    end

    assert_raise Ecto.NoResultsError, fn ->
      Topology.put_cable_plan(scope, %{interface_a_id: first.id, interface_b_id: foreign.id})
    end

    assert Topology.list_cables(scope) == []
    assert Topology.list_cable_plans(scope) == []
  end

  test "restricts confirmed cabling to managers while members reconcile", %{
    scope: scope,
    organization: organization
  } do
    first = interface_fixture(scope, "cable-auth-first", "eth0")
    second = interface_fixture(scope, "cable-auth-second", "swp1")

    {:ok, source} =
      Inventory.create_source(scope, %{kind: "manual", name: "cable-auth-source"})

    assert {:ok, _contract} = Topology.grant_cable_import_contract(scope, source.id)

    member = user_fixture()
    organization_membership_fixture(member, organization, %{role: "member"})
    member_scope = Accounts.scope_for_user(member, organization.id)

    assert {:error, :forbidden} =
             Topology.assert_cable(member_scope, %{
               interface_a_id: first.id,
               interface_b_id: second.id
             })

    assert {:error, :forbidden} =
             Topology.put_cable_plan(member_scope, %{
               interface_a_id: first.id,
               interface_b_id: second.id
             })

    assert {:error, :forbidden} =
             Topology.import_cable_assertion(member_scope, source.id, %{
               interface_a_id: first.id,
               interface_b_id: second.id
             })

    # members still reconcile projections they did not authorize
    assert {:ok, []} = Topology.reconcile_cables(member_scope)

    assert {:ok, _assertion} =
             Topology.assert_cable(scope, %{interface_a_id: first.id, interface_b_id: second.id})

    assert {:ok, imported} =
             Topology.import_cable_assertion(scope, source.id, %{
               interface_a_id: first.id,
               interface_b_id: second.id,
               cable_type: "cat6a"
             })

    assert imported.kind == "import"
    assert imported.source_id == source.id
    assert is_nil(imported.actor_user_id)

    assert [cable] = Topology.list_cables(scope)
    assert cable.cable_type == "cat6a"
    assert cable.primary_assertion_id == imported.id

    # attribute changes are attributed to the importing source
    assert [created, updated] = Topology.list_cable_change_events(scope, cable.id)
    assert created.action == "created"
    assert created.actor_user_id == scope.user.id
    assert updated.action == "updated"
    assert updated.source_id == source.id
    assert is_nil(updated.actor_user_id)
    assert updated.changes["cable_type"] == %{"from" => nil, "to" => "cat6a"}
  end

  test "requires a manager-granted contract before a source can import confirmed cabling", %{
    scope: scope,
    organization: organization
  } do
    first = interface_fixture(scope, "cable-contract-first", "eth0")
    second = interface_fixture(scope, "cable-contract-second", "swp1")

    {:ok, source} = Inventory.create_source(scope, %{kind: "manual", name: "cable-contract"})

    # Organization membership of a source is provenance, not trust.
    assert {:error, :cable_import_not_granted} =
             Topology.import_cable_assertion(scope, source.id, %{
               interface_a_id: first.id,
               interface_b_id: second.id
             })

    assert Topology.list_cables(scope) == []

    member = user_fixture()
    organization_membership_fixture(member, organization, %{role: "member"})
    member_scope = Accounts.scope_for_user(member, organization.id)

    assert {:error, :forbidden} = Topology.grant_cable_import_contract(member_scope, source.id)

    assert {:ok, contract} = Topology.grant_cable_import_contract(scope, source.id)
    assert contract.source_id == source.id
    assert contract.granted_by_id == scope.user.id
    assert is_nil(contract.revoked_at)

    assert {:ok, imported} =
             Topology.import_cable_assertion(scope, source.id, %{
               interface_a_id: first.id,
               interface_b_id: second.id,
               cable_type: "cat6a"
             })

    assert imported.kind == "import"
    assert [cable] = Topology.list_cables(scope)

    # Revocation stops new imports but leaves retained claims and cabling valid.
    assert {:ok, revoked} = Topology.revoke_cable_import_contract(scope, source.id)
    assert revoked.revoked_at != nil
    assert revoked.revoked_by_id == scope.user.id

    assert {:error, :cable_import_not_granted} =
             Topology.import_cable_assertion(scope, source.id, %{
               interface_a_id: first.id,
               interface_b_id: second.id,
               cable_type: "dac"
             })

    assert [still_current] = Topology.list_cables(scope)
    assert still_current.id == cable.id
    assert length(Topology.list_cable_assertions(scope)) == 1

    assert {:error, :cable_import_contract_already_revoked} =
             Topology.revoke_cable_import_contract(scope, source.id)

    # Re-granting clears the revocation; an inactive source cannot be trusted.
    assert {:ok, regranted} = Topology.grant_cable_import_contract(scope, source.id)
    assert is_nil(regranted.revoked_at)
    assert regranted.granted_by_id == scope.user.id

    assert {:ok, _inactive} = Inventory.update_source(scope, source, %{status: "revoked"})

    assert {:error, :source_inactive} = Topology.grant_cable_import_contract(scope, source.id)

    assert {:error, :source_inactive} =
             Topology.import_cable_assertion(scope, source.id, %{
               interface_a_id: first.id,
               interface_b_id: second.id
             })

    # Contracts are tenant scoped like every other cable record.
    foreign_user = user_fixture()
    foreign_organization = organization_fixture()
    organization_membership_fixture(foreign_user, foreign_organization, %{role: "admin"})
    foreign_scope = Accounts.scope_for_user(foreign_user, foreign_organization.id)

    assert_raise Ecto.NoResultsError, fn ->
      Topology.grant_cable_import_contract(foreign_scope, source.id)
    end

    assert [listed] = Topology.list_cable_import_contracts(scope)
    assert listed.source_id == source.id
    assert Topology.list_cable_import_contracts(foreign_scope) == []
  end

  test "lets neighbor evidence propose but never create, move, or remove a cable", %{
    scope: scope
  } do
    local_resource = resource_fixture(scope, "cable-evidence-local")
    remote_resource = resource_fixture(scope, "cable-evidence-remote")
    other_resource = resource_fixture(scope, "cable-evidence-other")

    {:ok, local} = Inventory.create_interface(scope, local_resource.id, %{name: "eth0"})
    {:ok, remote} = Inventory.create_interface(scope, remote_resource.id, %{name: "swp1"})
    {:ok, other} = Inventory.create_interface(scope, other_resource.id, %{name: "swp2"})

    {:ok, source} = Inventory.create_source(scope, %{kind: "manual", name: "cable-evidence"})

    observation =
      observation_fixture(scope, source, "cable-evidence", ~U[2099-09-10 12:00:00Z], %{})

    assert {:ok, [evidence]} =
             reconcile_neighbors(scope, source, observation, local_resource, [
               %{
                 "name" => local.name,
                 "neighbors" => [neighbor(remote_resource.name, remote.name)]
               }
             ])

    assert Topology.list_cables(scope) == []

    assert {:ok, proposal} = Topology.propose_cable_from_neighbor_evidence(scope, evidence.id)
    assert proposal.kind == "neighbor_evidence"
    assert proposal.confirmation == "proposed"
    assert proposal.interface_neighbor_evidence_id == evidence.id

    # a proposal stays invisible to reconciliation
    assert {:ok, []} = Topology.reconcile_cables(scope)
    assert Topology.list_cables(scope) == []

    assert {:ok, _confirmed} =
             Topology.assert_cable(scope, %{
               interface_a_id: local.id,
               interface_b_id: remote.id,
               cable_type: "cat6a"
             })

    assert [cable] = Topology.list_cables(scope)

    drift_observation =
      observation_fixture(scope, source, "cable-evidence-drift", ~U[2099-09-10 13:00:00Z], %{})

    assert {:ok, [_evidence]} =
             reconcile_neighbors(scope, source, drift_observation, local_resource, [
               %{
                 "name" => local.name,
                 "neighbors" => [neighbor(other_resource.name, other.name)]
               }
             ])

    assert [unchanged] = Topology.list_cables(scope)
    assert unchanged.id == cable.id
    assert unchanged.interface_a_id == cable.interface_a_id
    assert unchanged.interface_b_id == cable.interface_b_id

    assert Enum.any?(
             Topology.list_topology_findings(scope, local.id),
             &(&1.kind == "cable_neighbor_mismatch")
           )

    # the proposal never became current cabling
    assert Enum.map(Topology.list_cables(scope), & &1.id) == [cable.id]
  end

  test "keeps cable plans, assertions, and cables organization scoped", %{scope: scope} do
    first = interface_fixture(scope, "cable-scope-first", "eth0")
    second = interface_fixture(scope, "cable-scope-second", "swp1")

    assert {:ok, _assertion} =
             Topology.assert_cable(scope, %{interface_a_id: first.id, interface_b_id: second.id})

    assert {:ok, _plan} =
             Topology.put_cable_plan(scope, %{interface_a_id: first.id, interface_b_id: second.id})

    assert [cable] = Topology.list_cables(scope)
    assert [plan] = Topology.list_cable_plans(scope)
    assert [assertion] = Topology.list_cable_assertions(scope)
    assert assertion.organization_id == scope.organization_id

    foreign_user = user_fixture()
    foreign_organization = organization_fixture()
    organization_membership_fixture(foreign_user, foreign_organization, %{role: "admin"})
    foreign_scope = Accounts.scope_for_user(foreign_user, foreign_organization.id)

    assert Topology.list_cables(foreign_scope) == []
    assert Topology.list_cable_plans(foreign_scope) == []
    assert Topology.list_cable_assertions(foreign_scope) == []
    assert Topology.list_cable_change_events(foreign_scope, cable.id) == []
    assert Topology.list_interface_cable_change_events(foreign_scope, first.id) == []
    assert_raise Ecto.NoResultsError, fn -> Topology.get_cable!(foreign_scope, cable.id) end
    assert_raise Ecto.NoResultsError, fn -> Topology.get_cable_plan!(foreign_scope, plan.id) end

    # the database rejects cross-organization cable claims even when constructed directly
    foreign_resource = resource_fixture(foreign_scope, "cable-scope-foreign")

    {:ok, foreign_interface} =
      Inventory.create_interface(foreign_scope, foreign_resource.id, %{name: "eth0"})

    [interface_a_id, interface_b_id] = Enum.sort([first.id, foreign_interface.id])

    rejected =
      %CableAssertion{
        organization_id: scope.organization_id,
        interface_a_id: interface_a_id,
        interface_b_id: interface_b_id,
        actor_user_id: scope.user.id
      }
      |> CableAssertion.changeset(%{
        kind: "operator",
        action: "assert",
        confirmation: "confirmed",
        asserted_at: Renga.Time.utc_now_ms()
      })

    assert {:error, rejected_changeset} = Repo.insert(rejected)
    rejected_errors = errors_on(rejected_changeset)

    assert "does not exist" in (rejected_errors[:interface_a] || []) or
             "does not exist" in (rejected_errors[:interface_b] || [])
  end

  test "database rejects cable occupancy tampering and endpoint mutation", %{scope: scope} do
    first = interface_fixture(scope, "cable-guard-first", "eth0")
    second = interface_fixture(scope, "cable-guard-second", "swp1")
    unrelated = interface_fixture(scope, "cable-guard-unrelated", "swp2")

    assert {:ok, _assertion} =
             Topology.assert_cable(scope, %{interface_a_id: first.id, interface_b_id: second.id})

    assert [cable] = Topology.list_cables(scope)

    # The reconciler retires a displaced cable before installing its successor,
    # so the occupancy key is exercised directly: a second cable backed by a
    # matching confirmed claim cannot reuse a terminated endpoint.
    second = interface_fixture(scope, "cable-guard-second-port", "swp3")
    claim = insert_cable_claim!(scope, first, second, ~U[2026-09-16 11:00:00.000000Z])

    assert_raise Ecto.ConstraintError, ~r/cable_endpoint_terminations_pkey/, fn ->
      insert_cable_row!(scope, claim)
    end

    assert_raise Postgrex.Error, ~r/cable endpoint termination is inconsistent/, fn ->
      Repo.transaction(fn ->
        Repo.query!(
          "DELETE FROM cable_endpoint_terminations WHERE organization_id = $1::text::uuid AND interface_id = $2::text::uuid",
          [scope.organization_id, first.id]
        )

        Repo.query!("SET CONSTRAINTS cable_endpoint_terminations_enforce_consistency IMMEDIATE")
      end)
    end

    assert_raise Postgrex.Error, ~r/cable endpoints are immutable/, fn ->
      Repo.update_all(
        from(item in Cable, where: item.id == ^cable.id),
        set: [interface_b_id: unrelated.id]
      )
    end
  end

  test "interface inventory changes refresh cable plan feasibility without neighbor evidence", %{
    scope: scope
  } do
    first = interface_fixture(scope, "cable-refresh-first", "eth0")
    bridge = interface_fixture(scope, "cable-refresh-bridge", "br0", %{kind: "bridge"})

    assert {:ok, _plan} =
             Topology.put_cable_plan(scope, %{
               interface_a_id: first.id,
               interface_b_id: bridge.id
             })

    assert Enum.any?(
             findings_for(scope, [first.id, bridge.id]),
             &(&1.kind == "cable_plan_infeasible")
           )

    assert Topology.current_interface_cable_state?(scope)

    # The collector now reports the port as physical. An unrelated interface
    # mutation must still re-evaluate cable state, which has no neighbor
    # evidence to piggyback on.
    Repo.update_all(from(item in Interface, where: item.id == ^bridge.id),
      set: [kind: "ethernet"]
    )

    resource = resource_fixture(scope, "cable-refresh-extra")
    assert {:ok, _interface} = Inventory.create_interface(scope, resource.id, %{name: "eth1"})

    refute Enum.any?(
             findings_for(scope, [first.id, bridge.id]),
             &(&1.kind == "cable_plan_infeasible")
           )
  end

  test "updates an existing cable plan instead of inserting a duplicate", %{scope: scope} do
    first = interface_fixture(scope, "cable-plan-update-first", "eth0")
    second = interface_fixture(scope, "cable-plan-update-second", "swp1")

    assert {:ok, plan} =
             Topology.put_cable_plan(scope, %{
               interface_a_id: first.id,
               interface_b_id: second.id,
               cable_type: "cat6a",
               label: "first"
             })

    assert {:ok, updated} =
             Topology.put_cable_plan(scope, %{
               interface_a_id: second.id,
               interface_b_id: first.id,
               cable_type: "dac",
               label: "second",
               length_value: "3",
               length_unit: "m"
             })

    assert updated.id == plan.id
    assert updated.cable_type == "dac"
    assert updated.label == "second"
    assert Decimal.equal?(updated.length_value, Decimal.new("3"))

    assert [stored] = Topology.list_cable_plans(scope)
    assert stored.id == plan.id
    assert stored.label == "second"
  end

  test "accepts string-keyed attributes without letting callers classify a claim", %{scope: scope} do
    first = interface_fixture(scope, "cable-keys-first", "eth0")
    second = interface_fixture(scope, "cable-keys-second", "swp1")

    assert {:ok, assertion} =
             Topology.assert_cable(scope, %{
               "interface_a_id" => second.id,
               "interface_b_id" => first.id,
               "cable_type" => "cat6a",
               "kind" => "import",
               "action" => "retract",
               "confirmation" => "proposed"
             })

    assert assertion.kind == "operator"
    assert assertion.action == "assert"
    assert assertion.confirmation == "confirmed"
    assert assertion.actor_user_id == scope.user.id
    assert assertion.interface_a_id < assertion.interface_b_id

    assert [cable] = Topology.list_cables(scope)
    assert cable.cable_type == "cat6a"

    assert {:ok, retraction} =
             Topology.retract_cable(scope, %{
               "interface_a_id" => first.id,
               "interface_b_id" => second.id,
               "kind" => "operator",
               "action" => "assert"
             })

    assert retraction.action == "retract"
    assert Topology.list_cables(scope) == []

    {:ok, source} = Inventory.create_source(scope, %{kind: "manual", name: "cable-keys-source"})

    assert {:ok, _contract} = Topology.grant_cable_import_contract(scope, source.id)

    assert {:ok, imported} =
             Topology.import_cable_assertion(scope, source.id, %{
               "interface_a_id" => first.id,
               "interface_b_id" => second.id,
               "confirmation" => "proposed"
             })

    assert imported.kind == "import"
    assert imported.confirmation == "confirmed"
    assert imported.source_id == source.id

    assert {:ok, _plan} =
             Topology.put_cable_plan(scope, %{
               "interface_a_id" => first.id,
               "interface_b_id" => second.id,
               "status" => "planned"
             })

    assert [plan] = Topology.list_cable_plans(scope)
    assert plan.status == "planned"
  end

  test "retains confirmed cabling when an endpoint is reclassified and still allows retraction",
       %{
         scope: scope
       } do
    first = interface_fixture(scope, "cable-reclass-first", "eth0")
    second = interface_fixture(scope, "cable-reclass-second", "swp1")

    assert {:ok, _assertion} =
             Topology.assert_cable(scope, %{
               interface_a_id: first.id,
               interface_b_id: second.id,
               cable_type: "cat6a"
             })

    assert [cable] = Topology.list_cables(scope)

    Repo.update_all(from(item in Interface, where: item.id == ^second.id), set: [kind: "bridge"])

    # A collector reclassification never removes cabling on its own: the
    # contradiction becomes a finding.
    assert {:ok, [retained]} = Topology.reconcile_cables(scope)
    assert retained.id == cable.id
    assert retained.cable_type == "cat6a"

    assert [finding] =
             Topology.list_topology_findings(scope, second.id)
             |> Enum.filter(&(&1.kind == "cable_endpoint_infeasible"))

    assert finding.details["cable_id"] == cable.id

    # The authorized removal path still works even though the endpoint is no
    # longer physically connectable.
    assert {:ok, _retraction} =
             Topology.retract_cable(scope, %{interface_a_id: first.id, interface_b_id: second.id})

    assert Topology.list_cables(scope) == []

    refute Enum.any?(
             Topology.list_topology_findings(scope, second.id),
             &(&1.kind == "cable_endpoint_infeasible")
           )
  end

  test "orders same-millisecond claims by insertion sequence", %{scope: scope} do
    first = interface_fixture(scope, "cable-sequence-first", "eth0")
    second = interface_fixture(scope, "cable-sequence-second", "swp1")
    third = interface_fixture(scope, "cable-sequence-third", "swp2")
    at = ~U[2026-09-16 10:00:00.000000Z]

    # A later retraction wins even when it shares the assertion timestamp.
    assert {:ok, _assertion} =
             Topology.assert_cable(scope, %{
               interface_a_id: first.id,
               interface_b_id: second.id,
               asserted_at: at
             })

    assert {:ok, _retraction} =
             Topology.retract_cable(scope, %{
               interface_a_id: first.id,
               interface_b_id: second.id,
               asserted_at: at
             })

    assert Topology.list_cables(scope) == []

    # A later claim wins a contested endpoint at the same timestamp.
    assert {:ok, _older} =
             Topology.assert_cable(scope, %{
               interface_a_id: first.id,
               interface_b_id: second.id,
               asserted_at: at
             })

    assert {:ok, _newer} =
             Topology.assert_cable(scope, %{
               interface_a_id: first.id,
               interface_b_id: third.id,
               asserted_at: at
             })

    assert [cable] = Topology.list_cables(scope)
    assert cable.interface_a_id == Enum.min([first.id, third.id])
    assert cable.interface_b_id == Enum.max([first.id, third.id])

    # A later claim for the same pair replaces its attributes.
    assert {:ok, latest} =
             Topology.assert_cable(scope, %{
               interface_a_id: first.id,
               interface_b_id: third.id,
               cable_type: "cat6a",
               asserted_at: at
             })

    assert [updated] = Topology.list_cables(scope)
    assert updated.cable_type == "cat6a"
    assert updated.primary_assertion_id == latest.id
  end

  test "rejects future-dated confirmed claims so later mutations still win", %{scope: scope} do
    first = interface_fixture(scope, "cable-future-first", "eth0")
    second = interface_fixture(scope, "cable-future-second", "swp1")

    future = DateTime.add(Renga.Time.utc_now_ms(), 86_400, :second)

    assert {:error, :cable_asserted_at_in_future} =
             Topology.assert_cable(scope, %{
               interface_a_id: first.id,
               interface_b_id: second.id,
               asserted_at: future
             })

    assert {:error, :cable_asserted_at_in_future} =
             Topology.retract_cable(scope, %{
               "interface_a_id" => first.id,
               "interface_b_id" => second.id,
               "asserted_at" => future
             })

    {:ok, source} = Inventory.create_source(scope, %{kind: "manual", name: "cable-future"})

    assert {:ok, _contract} = Topology.grant_cable_import_contract(scope, source.id)

    assert {:error, :cable_asserted_at_in_future} =
             Topology.import_cable_assertion(scope, source.id, %{
               interface_a_id: first.id,
               interface_b_id: second.id,
               asserted_at: future
             })

    # Rejected claims leave no trace: no claim, no cabling, no history.
    assert Topology.list_cable_assertions(scope) == []
    assert Topology.list_cables(scope) == []

    # Ordinary mutations still work; a future retraction cannot suppress them.
    assert {:ok, _assertion} =
             Topology.assert_cable(scope, %{interface_a_id: first.id, interface_b_id: second.id})

    assert [cable] = Topology.list_cables(scope)

    assert {:ok, _retraction} =
             Topology.retract_cable(scope, %{interface_a_id: first.id, interface_b_id: second.id})

    assert Topology.list_cables(scope) == []
    assert length(Topology.list_cable_assertions(scope)) == 2
    assert length(Topology.list_cable_change_events(scope, cable.id)) == 2
  end

  test "records who caused a cable transition and what the cable was", %{scope: scope} do
    first = interface_fixture(scope, "cable-history-first", "eth0")
    second = interface_fixture(scope, "cable-history-second", "swp1")

    assert {:ok, assertion} =
             Topology.assert_cable(scope, %{
               interface_a_id: first.id,
               interface_b_id: second.id,
               cable_type: "cat6a",
               label: "uplink"
             })

    assert [cable] = Topology.list_cables(scope)

    assert [created] = Topology.list_cable_change_events(scope, cable.id)
    assert created.assertion_id == assertion.id
    assert created.actor_user_id == scope.user.id
    assert created.snapshot["cable_type"] == "cat6a"
    assert created.snapshot["label"] == "uplink"

    remover = user_fixture()
    organization_membership_fixture(remover, scope.organization, %{role: "admin"})
    remover_scope = Accounts.scope_for_user(remover, scope.organization.id)

    assert {:ok, retraction} =
             Topology.retract_cable(remover_scope, %{
               interface_a_id: first.id,
               interface_b_id: second.id
             })

    assert [^created, removed] = Topology.list_cable_change_events(scope, cable.id)
    assert removed.action == "removed"
    assert removed.assertion_id == retraction.id
    assert removed.actor_user_id == remover.id
    assert removed.snapshot["cable_type"] == "cat6a"
    assert removed.snapshot["label"] == "uplink"
  end

  test "attributes a displaced cable's removal to the claim that replaced it", %{scope: scope} do
    first = interface_fixture(scope, "cable-displace-first", "eth0")
    second = interface_fixture(scope, "cable-displace-second", "swp1")
    third = interface_fixture(scope, "cable-displace-third", "swp2")

    assert {:ok, _older} =
             Topology.assert_cable(scope, %{
               interface_a_id: first.id,
               interface_b_id: second.id,
               cable_type: "cat6a",
               asserted_at: ~U[2026-09-16 10:00:00.000000Z]
             })

    assert [displaced] = Topology.list_cables(scope)

    replacer = user_fixture()
    organization_membership_fixture(replacer, scope.organization, %{role: "admin"})
    replacer_scope = Accounts.scope_for_user(replacer, scope.organization.id)

    assert {:ok, replacement} =
             Topology.assert_cable(replacer_scope, %{
               interface_a_id: first.id,
               interface_b_id: third.id,
               cable_type: "dac",
               asserted_at: ~U[2026-09-16 11:00:00.000000Z]
             })

    assert [_created, removed] = Topology.list_cable_change_events(scope, displaced.id)
    assert removed.action == "removed"
    assert removed.assertion_id == replacement.id
    assert removed.actor_user_id == replacer.id
    assert removed.snapshot["cable_type"] == "cat6a"
  end

  test "attributes a removal to the displacing claim's precedence, not endpoint order", %{
    scope: scope,
    organization: organization
  } do
    interfaces =
      for index <- 1..4 do
        interface_fixture(scope, "cable-cause-#{index}", "eth#{index}")
      end

    # The removed cable must start at the lowest endpoint id, so attributing the
    # removal to the first endpoint deterministically picked the wrong claim.
    {first, second} = interfaces |> Enum.take(2) |> Enum.min_max_by(& &1.id)
    [third, fourth] = Enum.drop(interfaces, 2)

    bob = user_fixture()
    organization_membership_fixture(bob, organization, %{role: "admin"})
    bob_scope = Accounts.scope_for_user(bob, organization.id)

    carol = user_fixture()
    organization_membership_fixture(carol, organization, %{role: "admin"})
    carol_scope = Accounts.scope_for_user(carol, organization.id)

    # Alice's older claim is blocked while Bob's cable is current.
    assert {:ok, _alice_claim} =
             Topology.assert_cable(scope, %{
               interface_a_id: first.id,
               interface_b_id: third.id,
               asserted_at: ~U[2026-09-16 10:00:00.000000Z]
             })

    assert {:ok, _bob_claim} =
             Topology.assert_cable(bob_scope, %{
               interface_a_id: first.id,
               interface_b_id: second.id,
               asserted_at: ~U[2026-09-16 11:00:00.000000Z]
             })

    assert [displaced] = Topology.list_cables(scope)

    # Carol's newer claim takes the second endpoint. Alice's claim is only
    # reactivated; it did not displace Bob's cable by precedence.
    assert {:ok, carol_claim} =
             Topology.assert_cable(carol_scope, %{
               interface_a_id: second.id,
               interface_b_id: fourth.id,
               asserted_at: ~U[2026-09-16 12:00:00.000000Z]
             })

    assert length(Topology.list_cables(scope)) == 2

    assert [created, removed] = Topology.list_cable_change_events(scope, displaced.id)
    assert created.action == "created"
    assert removed.action == "removed"
    assert removed.assertion_id == carol_claim.id
    assert removed.actor_user_id == carol.id
  end

  test "normalizes equivalent colors so reasserting does not fabricate changes", %{scope: scope} do
    first = interface_fixture(scope, "cable-color-first", "eth0")
    second = interface_fixture(scope, "cable-color-second", "swp1")

    assert {:ok, _assertion} =
             Topology.assert_cable(scope, %{
               interface_a_id: first.id,
               interface_b_id: second.id,
               color: "#AA00BB",
               cable_type: "cat6a"
             })

    assert [cable] = Topology.list_cables(scope)
    assert cable.color == "#aa00bb"

    assert {:ok, _plan} =
             Topology.put_cable_plan(scope, %{
               interface_a_id: first.id,
               interface_b_id: second.id,
               color: "#aa00bb",
               cable_type: "cat6a"
             })

    refute Enum.any?(
             findings_for(scope, [first.id, second.id]),
             &(&1.kind == "cable_plan_drift")
           )

    # Reasserting the same color in a different case records no attribute change.
    assert {:ok, _reassertion} =
             Topology.assert_cable(scope, %{
               interface_a_id: first.id,
               interface_b_id: second.id,
               color: "#AA00BB",
               cable_type: "cat6a"
             })

    assert [_created] = Topology.list_cable_change_events(scope, cable.id)
  end

  test "rejects cable lengths the column cannot store", %{scope: scope} do
    first = interface_fixture(scope, "cable-length-first", "eth0")
    second = interface_fixture(scope, "cable-length-second", "swp1")

    assert {:error, changeset} =
             Topology.assert_cable(scope, %{
               interface_a_id: first.id,
               interface_b_id: second.id,
               length_value: "1000000000",
               length_unit: "m"
             })

    assert "must be less than or equal to 999999999.999" in errors_on(changeset).length_value

    # numeric(12,3) rounds to the declared scale before the precision check, so
    # a value that rounds up to 1000000000.000 would overflow.
    assert {:error, rounded} =
             Topology.assert_cable(scope, %{
               interface_a_id: first.id,
               interface_b_id: second.id,
               length_value: "999999999.9994",
               length_unit: "m"
             })

    assert "must be less than or equal to 999999999.999" in errors_on(rounded).length_value

    assert {:error, plan_changeset} =
             Topology.put_cable_plan(scope, %{
               interface_a_id: first.id,
               interface_b_id: second.id,
               length_value: "999999999.9995",
               length_unit: "m"
             })

    assert "must be less than or equal to 999999999.999" in errors_on(plan_changeset).length_value

    assert {:ok, _assertion} =
             Topology.assert_cable(scope, %{
               interface_a_id: first.id,
               interface_b_id: second.id,
               length_value: "999999999.999",
               length_unit: "m"
             })

    assert [cable] = Topology.list_cables(scope)
    assert Decimal.equal?(cable.length_value, Decimal.new("999999999.999"))
  end

  test "database rejects cables that their primary assertion does not support", %{scope: scope} do
    {evidence, local, remote} = neighbor_evidence!(scope, "cable-support")

    assert {:ok, proposal} = Topology.propose_cable_from_neighbor_evidence(scope, evidence.id)

    assert_raise Postgrex.Error, ~r/must be a confirmed cable claim/, fn ->
      insert_cable_row!(scope, proposal)
    end

    assert {:ok, retraction} =
             Topology.retract_cable(scope, %{interface_a_id: local.id, interface_b_id: remote.id})

    assert_raise Postgrex.Error, ~r/must be a confirmed cable claim/, fn ->
      insert_cable_row!(scope, retraction)
    end

    first = interface_fixture(scope, "cable-support-first", "eth0")
    second = interface_fixture(scope, "cable-support-second", "swp1")
    third = interface_fixture(scope, "cable-support-third", "swp2")
    claim = insert_cable_claim!(scope, first, second, ~U[2026-09-16 10:00:00.000000Z])

    [interface_a_id, interface_b_id] = Enum.sort([first.id, third.id])

    mismatched =
      %Cable{
        organization_id: scope.organization_id,
        interface_a_id: interface_a_id,
        interface_b_id: interface_b_id,
        primary_assertion_id: claim.id
      }
      |> Ecto.Changeset.change(last_asserted_at: claim.asserted_at)
      |> Cable.changeset(%{status: "connected", metadata: %{}})

    assert_raise Postgrex.Error, ~r/endpoints must match its primary assertion/, fn ->
      Repo.insert!(mismatched)
    end
  end

  test "keeps assertions append-only and attributable across deletions", %{scope: scope} do
    user = scope.user

    first = interface_fixture(scope, "cable-retention-first", "eth0")
    second = interface_fixture(scope, "cable-retention-second", "swp1")

    {:ok, source} = Inventory.create_source(scope, %{kind: "manual", name: "cable-retention"})

    assert {:ok, _contract} = Topology.grant_cable_import_contract(scope, source.id)

    assert {:ok, _assertion} =
             Topology.assert_cable(scope, %{interface_a_id: first.id, interface_b_id: second.id})

    assert {:ok, _imported} =
             Topology.import_cable_assertion(scope, source.id, %{
               interface_a_id: first.id,
               interface_b_id: second.id,
               cable_type: "cat6a"
             })

    # Direct assertion deletion would cascade current cabling away with no
    # removal event, so it is rejected while the organization exists.
    assert_raise Postgrex.Error, ~r/append-only and cannot be deleted/, fn ->
      Repo.query!(
        "DELETE FROM cable_assertions WHERE organization_id = $1::text::uuid",
        [scope.organization_id]
      )
    end

    # Deleting an importing source would cascade the same way.
    assert_raise Postgrex.Error, ~r/append-only and cannot be deleted/, fn ->
      Repo.delete(source)
    end

    # Deleting an attributed actor is rejected instead of rewriting provenance.
    assert_raise Ecto.ConstraintError, ~r/cable_assertions/, fn ->
      Repo.delete(user)
    end

    assert length(Topology.list_cable_assertions(scope)) == 2
    assert length(Topology.list_cables(scope)) == 1

    # Organization teardown still cascades deliberately.
    assert {:ok, _deleted} = Repo.delete(scope.organization)
    assert Repo.aggregate(CableAssertion, :count) == 0
  end

  test "allows members to propose from evidence while confirmed cabling stays manager-only", %{
    scope: scope,
    organization: organization
  } do
    {evidence, local, remote} = neighbor_evidence!(scope, "cable-proposal-auth")
    other = interface_fixture(scope, "cable-proposal-auth-other", "swp2")

    member = user_fixture()
    organization_membership_fixture(member, organization, %{role: "member"})
    member_scope = Accounts.scope_for_user(member, organization.id)

    # A member cannot forge endpoints or a timestamp on the first proposal for
    # fresh evidence: the facts come from the evidence, never caller input.
    assert {:ok, proposal} =
             Topology.propose_cable_from_neighbor_evidence(member_scope, evidence.id, %{
               "interface_a_id" => local.id,
               "interface_b_id" => other.id,
               "asserted_at" => ~U[2030-01-01 00:00:00Z]
             })

    assert proposal.kind == "neighbor_evidence"
    assert proposal.action == "assert"
    assert proposal.confirmation == "proposed"
    assert proposal.interface_neighbor_evidence_id == evidence.id
    assert proposal.interface_a_id == Enum.min([local.id, remote.id])
    assert proposal.interface_b_id == Enum.max([local.id, remote.id])
    assert proposal.asserted_at == evidence.observed_at
    assert is_nil(proposal.actor_user_id)

    assert Topology.list_cables(scope) == []

    # Retries reuse the attributed proposal instead of re-forging it.
    assert {:ok, unchanged} =
             Topology.propose_cable_from_neighbor_evidence(member_scope, evidence.id, %{
               interface_a_id: other.id,
               interface_b_id: local.id,
               asserted_at: ~U[2031-01-01 00:00:00Z]
             })

    assert unchanged.id == proposal.id
    assert unchanged.interface_a_id == proposal.interface_a_id
    assert unchanged.interface_b_id == proposal.interface_b_id
    assert unchanged.asserted_at == evidence.observed_at

    assert {:error, :forbidden} =
             Topology.assert_cable(member_scope, %{
               interface_a_id: local.id,
               interface_b_id: remote.id
             })
  end

  test "refuses to propose from expired neighbor evidence", %{scope: scope} do
    local_resource = resource_fixture(scope, "cable-expiry-local")
    remote_resource = resource_fixture(scope, "cable-expiry-remote")
    {:ok, local} = Inventory.create_interface(scope, local_resource.id, %{name: "eth0"})
    {:ok, remote} = Inventory.create_interface(scope, remote_resource.id, %{name: "swp1"})
    {:ok, source} = Inventory.create_source(scope, %{kind: "manual", name: "cable-expiry"})

    observed_at = Renga.Time.utc_now_ms()
    observation = observation_fixture(scope, source, "cable-expiry", observed_at, %{})

    assert {:ok, [evidence]} =
             reconcile_neighbors(scope, source, observation, local_resource, [
               %{
                 "name" => local.name,
                 "neighbors" => [
                   neighbor(remote_resource.name, remote.name, %{"ttl_seconds" => 1})
                 ]
               }
             ])

    assert Repo.get_by(InterfaceNeighborMatch, interface_neighbor_evidence_id: evidence.id).status ==
             "matched"

    # The TTL elapses before the expiry sweep runs: a matched row and an unset
    # stale marker are not freshness.
    Process.sleep(1_100)

    assert is_nil(Repo.get!(InterfaceNeighborEvidence, evidence.id).stale_at)

    assert {:error, :neighbor_evidence_stale} =
             Topology.propose_cable_from_neighbor_evidence(scope, evidence.id)

    # After the sweep marks it expired the proposal is still refused.
    assert {:ok, _adjacencies} =
             Topology.expire_interface_neighbors(scope, DateTime.add(observed_at, 60, :second))

    assert Repo.get!(InterfaceNeighborEvidence, evidence.id).stale_reason == "expired"

    assert {:error, :neighbor_evidence_stale} =
             Topology.propose_cable_from_neighbor_evidence(scope, evidence.id)

    assert Topology.list_cable_assertions(scope) == []
    assert Topology.list_cables(scope) == []
  end

  test "refuses to propose from superseded or withdrawn neighbor evidence", %{scope: scope} do
    local_resource = resource_fixture(scope, "cable-stale-local")
    remote_resource = resource_fixture(scope, "cable-stale-remote")
    {:ok, local} = Inventory.create_interface(scope, local_resource.id, %{name: "eth0"})
    {:ok, remote} = Inventory.create_interface(scope, remote_resource.id, %{name: "swp1"})

    {:ok, source} =
      Inventory.create_source(scope, %{
        kind: "manual",
        name: "cable-stale",
        metadata: %{"interface_neighbor_snapshot_policy" => "complete"}
      })

    observed_at = Renga.Time.utc_now_ms()

    first =
      observation_fixture(scope, source, "cable-stale-1", observed_at, %{
        "section_completeness" => %{"interface_neighbors" => true}
      })

    assert {:ok, [superseded]} =
             reconcile_neighbors(scope, source, first, local_resource, [
               %{
                 "name" => local.name,
                 "neighbors" => [
                   neighbor(remote_resource.name, remote.name, %{"ttl_seconds" => 600})
                 ]
               }
             ])

    second =
      observation_fixture(
        scope,
        source,
        "cable-stale-2",
        DateTime.add(observed_at, 60, :second),
        %{
          "section_completeness" => %{"interface_neighbors" => true}
        }
      )

    assert {:ok, [fresh]} =
             reconcile_neighbors(scope, source, second, local_resource, [
               %{
                 "name" => local.name,
                 "neighbors" => [
                   neighbor(remote_resource.name, remote.name, %{"ttl_seconds" => 600})
                 ]
               }
             ])

    assert Repo.get!(InterfaceNeighborEvidence, superseded.id).stale_reason == "superseded"

    assert {:error, :neighbor_evidence_stale} =
             Topology.propose_cable_from_neighbor_evidence(scope, superseded.id)

    # The newest report is still proposable: freshness is not over-blocked.
    assert {:ok, proposal} = Topology.propose_cable_from_neighbor_evidence(scope, fresh.id)
    assert proposal.interface_neighbor_evidence_id == fresh.id

    # A complete snapshot without the neighbor withdraws the older report.
    third =
      observation_fixture(
        scope,
        source,
        "cable-stale-3",
        DateTime.add(observed_at, 120, :second),
        %{
          "section_completeness" => %{"interface_neighbors" => true}
        }
      )

    assert {:ok, []} = reconcile_neighbors(scope, source, third, local_resource, [])

    assert Repo.get!(InterfaceNeighborEvidence, fresh.id).stale_reason == "withdrawn"

    assert {:error, :neighbor_evidence_stale} =
             Topology.propose_cable_from_neighbor_evidence(scope, fresh.id)

    assert length(Topology.list_cable_assertions(scope)) == 1
    assert Topology.list_cables(scope) == []
  end

  test "collector observations refresh cable feasibility without neighbor evidence", %{
    scope: scope
  } do
    {:ok, source} =
      Inventory.create_source(scope, %{kind: "host_agent", name: "cable-collector-source"})

    observed_at = ~U[2026-09-16 12:00:00Z]

    first =
      observation_fixture(scope, source, "cable-collector-1", observed_at, %{
        "observation_id" => "cable-collector-1",
        "observed_at" => DateTime.to_iso8601(observed_at),
        "resources" => [
          %{
            "kind" => "server",
            "identifiers" => %{"machine_id" => "cable-collector-machine"},
            "attributes" => %{},
            "interfaces" => [
              %{"name" => "eth0", "kind" => "ethernet"},
              %{"name" => "br0", "kind" => "bridge"}
            ]
          }
        ]
      })

    assert {:ok, resource, _current?} = Inventory.reconcile_observation(scope, first.id)

    [br0, eth0] = Inventory.list_interfaces(scope, resource.id) |> Enum.sort_by(& &1.name)

    assert {:ok, _plan} =
             Topology.put_cable_plan(scope, %{
               interface_a_id: eth0.id,
               interface_b_id: br0.id,
               status: "planned"
             })

    assert Enum.any?(
             findings_for(scope, [eth0.id, br0.id]),
             &(&1.kind == "cable_plan_infeasible")
           )

    # The collector reports the port as physical. No neighbor evidence exists in
    # this organization, so cable state must be refreshed on its own.
    second =
      observation_fixture(scope, source, "cable-collector-2", DateTime.add(observed_at, 60), %{
        "observation_id" => "cable-collector-2",
        "observed_at" => DateTime.to_iso8601(DateTime.add(observed_at, 60)),
        "resources" => [
          %{
            "kind" => "server",
            "identifiers" => %{"machine_id" => "cable-collector-machine"},
            "attributes" => %{},
            "interfaces" => [
              %{"name" => "eth0", "kind" => "ethernet"},
              %{"name" => "br0", "kind" => "ethernet"}
            ]
          }
        ]
      })

    assert {:ok, _resource, _current?} = Inventory.reconcile_observation(scope, second.id)

    refute Enum.any?(
             findings_for(scope, [eth0.id, br0.id]),
             &(&1.kind == "cable_plan_infeasible")
           )

    # Reporting the bridge again reopens the finding.
    third =
      observation_fixture(scope, source, "cable-collector-3", DateTime.add(observed_at, 120), %{
        "observation_id" => "cable-collector-3",
        "observed_at" => DateTime.to_iso8601(DateTime.add(observed_at, 120)),
        "resources" => [
          %{
            "kind" => "server",
            "identifiers" => %{"machine_id" => "cable-collector-machine"},
            "attributes" => %{},
            "interfaces" => [
              %{"name" => "eth0", "kind" => "ethernet"},
              %{"name" => "br0", "kind" => "bridge"}
            ]
          }
        ]
      })

    assert {:ok, _resource, _current?} = Inventory.reconcile_observation(scope, third.id)

    assert Enum.any?(
             findings_for(scope, [eth0.id, br0.id]),
             &(&1.kind == "cable_plan_infeasible")
           )
  end

  defp neighbor_evidence!(scope, tag) do
    local_resource = resource_fixture(scope, "#{tag}-local")
    remote_resource = resource_fixture(scope, "#{tag}-remote")
    {:ok, local} = Inventory.create_interface(scope, local_resource.id, %{name: "eth0"})
    {:ok, remote} = Inventory.create_interface(scope, remote_resource.id, %{name: "swp1"})
    {:ok, source} = Inventory.create_source(scope, %{kind: "manual", name: "#{tag}-source"})

    observation = observation_fixture(scope, source, tag, ~U[2099-09-10 12:00:00Z], %{})

    assert {:ok, [evidence]} =
             reconcile_neighbors(scope, source, observation, local_resource, [
               %{
                 "name" => local.name,
                 "neighbors" => [neighbor(remote_resource.name, remote.name)]
               }
             ])

    {evidence, local, remote}
  end

  defp insert_cable_claim!(scope, first, second, asserted_at) do
    [interface_a_id, interface_b_id] = Enum.sort([first.id, second.id])

    %CableAssertion{
      organization_id: scope.organization_id,
      interface_a_id: interface_a_id,
      interface_b_id: interface_b_id,
      actor_user_id: scope.user.id
    }
    |> CableAssertion.changeset(%{
      kind: "operator",
      action: "assert",
      confirmation: "confirmed",
      asserted_at: asserted_at
    })
    |> Repo.insert!()
  end

  defp insert_cable_row!(scope, claim) do
    %Cable{
      organization_id: scope.organization_id,
      interface_a_id: claim.interface_a_id,
      interface_b_id: claim.interface_b_id,
      primary_assertion_id: claim.id
    }
    |> Ecto.Changeset.change(last_asserted_at: claim.asserted_at)
    |> Cable.changeset(%{status: "connected", metadata: %{}})
    |> Repo.insert!()
  end

  defp findings_for(scope, interface_ids) do
    interface_ids
    |> Enum.uniq()
    |> Enum.flat_map(&Topology.list_topology_findings(scope, &1))
  end

  defp interface_fixture(scope, resource_name, interface_name, attrs \\ %{}) do
    resource = resource_fixture(scope, resource_name)

    {:ok, interface} =
      Inventory.create_interface(scope, resource.id, Map.merge(%{name: interface_name}, attrs))

    interface
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

  defp reconcile_neighbors(
         scope,
         source,
         observation,
         resource,
         interfaces,
         current_snapshot? \\ true
       ) do
    Topology.reconcile_interface_neighbors(
      scope,
      source,
      observation,
      resource.id,
      interfaces,
      current_snapshot?
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

  defp prefix_fixture(scope, _resource_name, cidr) do
    {:ok, prefix} = Renga.IPAM.create_prefix(scope, %{prefix: cidr})
    prefix
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
