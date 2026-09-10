defmodule Renga.TopologyTest do
  use Renga.DataCase, async: true

  import Renga.AccountsFixtures
  import Renga.InventoryFixtures

  alias Renga.Accounts
  alias Renga.DCIM
  alias Renga.Inventory
  alias Renga.Inventory.Host
  alias Renga.Inventory.ResourceRevision
  alias Renga.Inventory.ResourceStore
  alias Renga.Repo
  alias Renga.Topology
  alias Renga.Topology.CurrentInterfaceAdjacency
  alias Renga.Topology.InterfaceNeighborEvidence
  alias Renga.Topology.InterfaceNeighborMatch
  alias Renga.Topology.InterfaceVlanEvidence
  alias Renga.Topology.InterfaceVlanModeEvidence
  alias Renga.Topology.NeighborExpiryWorker
  alias Renga.Topology.NeighborIdentifier
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
