defmodule Renga.Topology.NeighborGenerationTest do
  use Renga.DataCase, async: false
  import Renga.AccountsFixtures
  import Renga.InventoryFixtures
  alias Renga.{Accounts, Inventory, Topology}
  alias Renga.Accounts.Scope
  alias Renga.Topology.{NeighborGeneration, TopologyFinding}

  @observed ~U[2099-09-10 12:00:00Z]
  @as_of ~U[2099-09-10 12:00:31Z]

  setup do
    user = user_fixture()
    organization = organization_fixture()
    organization_membership_fixture(user, organization, %{role: "admin"})
    scope = Accounts.scope_for_user(user, organization.id)

    interfaces =
      for n <- 1..4 do
        {:ok, resource} =
          Inventory.create_resource(scope, %{
            kind: "server",
            name: "generation-#{n}",
            lifecycle_state: "active"
          })

        {:ok, interface} =
          Inventory.create_interface(scope, resource.id, %{
            name: "eth0",
            kind: "ethernet",
            mac_address: "02:00:00:00:00:0#{n}"
          })

        interface
      end

    [a, b, c, d] = interfaces
    {:ok, source} = Inventory.create_source(scope, %{name: "generation", kind: "manual"})
    report(scope, source, a, b, @observed, 30)
    report(scope, source, c, d, @observed, 600)

    {:ok, _assertion} =
      Topology.assert_cable(scope, %{interface_a_id: a.id, interface_b_id: c.id})

    %{
      scope: scope,
      worker: %Scope{organization_id: organization.id, roles: ["topology_reconciler"]},
      source: source,
      a: a,
      b: b,
      c: c,
      d: d
    }
  end

  test "restarted batches keep unvisited relationships/findings visible and publish all outputs together",
       context do
    %{scope: scope, worker: worker, a: a, b: b, c: c, d: d} = context
    before_pairs = pairs(scope)
    before_findings = findings(scope)
    cables = Topology.list_cables(scope) |> Enum.map(& &1.id)
    assert length(before_pairs) == 2
    assert {:ok, :building} = NeighborGeneration.step(worker, @as_of, batch_size: 1)

    for _ <- 1..2 do
      assert {:ok, :building} =
               Task.async(fn ->
                 NeighborGeneration.step(worker, DateTime.add(@as_of, 1800), batch_size: 1)
               end)
               |> Task.await()

      assert pairs(scope) == before_pairs
      assert findings(scope) == before_findings
    end

    finish(
      worker,
      fn ->
        assert pairs(scope) == before_pairs
        assert findings(scope) == before_findings
      end,
      DateTime.add(@as_of, 1800)
    )

    assert pairs(scope) == [Enum.sort([c.id, d.id])]
    refute Enum.sort([a.id, b.id]) in pairs(scope)
    assert Topology.list_cables(scope) |> Enum.map(& &1.id) == cables

    assert Enum.any?(
             Topology.list_topology_findings(scope, a.id),
             &(&1.kind == "expired_adjacency" and &1.status == "open")
           )

    assert Enum.any?(
             Topology.list_topology_findings(scope, a.id, "resolved"),
             &(&1.kind == "cable_neighbor_mismatch")
           )

    assert Enum.any?(
             Topology.list_topology_findings(scope, c.id),
             &(&1.kind == "cable_neighbor_mismatch" and &1.status == "open")
           )

    # A pre-generation writer materializes the published snapshot before its
    # own update; physical constraints and the visible topology still agree.
    Repo.update_all(from(i in Inventory.Interface, where: i.id == ^d.id), set: [name: "renamed"])
    assert pairs(scope) == [Enum.sort([c.id, d.id])]
  end

  test "new evidence invalidates staged expiry instead of deleting a renewed link", context do
    %{scope: scope, worker: worker, source: source, a: a, b: b} = context
    assert {:ok, :building} = NeighborGeneration.step(worker, @as_of, batch_size: 1)
    report(scope, source, a, b, DateTime.add(@observed, 40), 600)
    renewed = pairs(scope)
    assert {:ok, :invalidated} = NeighborGeneration.step(worker, @as_of, batch_size: 1)
    assert pairs(scope) == renewed
    assert Enum.sort([a.id, b.id]) in renewed
    assert {:ok, :cleaned} = NeighborGeneration.step(worker, @as_of)
    assert pairs(scope) == renewed
  end

  test "a timed-out batch rolls back only that batch and cannot resolve any visible finding",
       context do
    %{scope: scope, worker: worker} = context
    before_pairs = pairs(scope)
    before_findings = findings(scope)
    assert {:ok, :building} = NeighborGeneration.step(worker, @as_of, batch_size: 1)

    assert_raise Postgrex.Error, fn ->
      NeighborGeneration.step(worker, @as_of,
        batch_size: 1,
        after_batch: fn _ -> Repo.query!("SELECT pg_sleep(1)") end
      )
    end

    assert pairs(scope) == before_pairs
    assert findings(scope) == before_findings
    finish(worker, fn -> assert pairs(scope) == before_pairs end)
    assert length(pairs(scope)) == 1
  end

  test "published compaction resumes after timeout without changing links or finding history",
       context do
    %{scope: scope, worker: worker} = context
    finish(worker, fn -> :ok end)
    published_pairs = pairs(scope)
    published_findings = findings(scope)

    assert_raise Postgrex.Error, fn ->
      NeighborGeneration.step(worker, @as_of,
        batch_size: 1,
        after_batch: fn _ -> Repo.query!("SELECT pg_sleep(1)") end
      )
    end

    result =
      Enum.reduce_while(1..80, nil, fn _, _ ->
        result =
          Task.async(fn -> NeighborGeneration.step(worker, @as_of, batch_size: 1) end)
          |> Task.await()

        assert pairs(scope) == published_pairs
        assert findings(scope) == published_findings
        if result == {:ok, :cleaned}, do: {:halt, result}, else: {:cont, result}
      end)

    assert result == {:ok, :cleaned}

    assert [%{kind: "expired_adjacency"} | _] =
             Topology.list_topology_findings(scope, context.a.id)

    # A second generation must retain resolved history from the first, even
    # after its overlay rows have been reclaimed.
    finish(worker, fn -> :ok end, DateTime.add(@as_of, 600))
    assert pairs(scope) == []
    assert Enum.all?(published_findings, fn {id, _} -> Repo.get!(TopologyFinding, id) end)
  end

  test "an old writer during compaction keeps the published snapshot and fences a fully staged draft",
       context do
    %{scope: scope, worker: worker, source: source, a: a, b: b, d: d} = context
    finish(worker, fn -> :ok end)
    expected = pairs(scope)
    assert {:ok, :compacting} = NeighborGeneration.step(worker, @as_of, batch_size: 1)

    Repo.update_all(from(i in Inventory.Interface, where: i.id == ^d.id),
      set: [name: "old-writer"]
    )

    assert pairs(scope) == expected

    # Stage the whole later expiry, then renew evidence immediately before
    # publication. A version check must reject all staged deletes/resolutions.
    Enum.reduce_while(1..40, nil, fn _, _ ->
      assert {:ok, :building} =
               NeighborGeneration.step(worker, DateTime.add(@as_of, 600), batch_size: 1)

      phase =
        Repo.query!(
          "SELECT phase FROM neighbor_generations WHERE organization_id = $1 AND status = 'building'",
          [Ecto.UUID.dump!(scope.organization_id)]
        ).rows

      if phase == [["publish"]], do: {:halt, :ready}, else: {:cont, nil}
    end)
    |> then(&assert(&1 == :ready))

    report(scope, source, a, b, DateTime.add(@observed, 640), 600)
    renewed = pairs(scope)
    current_findings = findings(scope)
    assert {:ok, :invalidated} = NeighborGeneration.step(worker, DateTime.add(@as_of, 600))
    assert pairs(scope) == renewed
    assert findings(scope) == current_findings
    assert Enum.sort([a.id, b.id]) in renewed
  end

  defp finish(worker, unchanged, as_of \\ @as_of) do
    Enum.reduce_while(1..40, nil, fn _, _ ->
      case NeighborGeneration.step(worker, as_of, batch_size: 1) do
        {:ok, :published} ->
          {:halt, :published}

        {:ok, :building} ->
          unchanged.()
          {:cont, nil}
      end
    end)
    |> then(&assert(&1 == :published))
  end

  defp pairs(scope),
    do:
      Topology.list_current_interface_adjacencies(scope)
      |> Enum.map(&Enum.sort([&1.interface_a_id, &1.interface_b_id]))
      |> Enum.sort()

  defp findings(scope),
    do:
      Repo.all(
        from f in TopologyFinding,
          where: f.organization_id == ^scope.organization_id,
          order_by: f.id,
          select: {f.id, f.status}
      )

  defp report(scope, source, local, remote, observed, ttl) do
    mac =
      remote.mac_address.address
      |> Tuple.to_list()
      |> Enum.map_join(":", &(Integer.to_string(&1, 16) |> String.pad_leading(2, "0")))

    {:ok, observation} =
      Inventory.create_observation(scope, source.id, %{
        idempotency_key: Ecto.UUID.generate(),
        observed_at: observed,
        payload: %{}
      })

    {:ok, [_]} =
      Topology.reconcile_interface_neighbors(
        scope,
        source,
        observation,
        local.resource_id,
        [
          %{
            "name" => local.name,
            "neighbors" => [
              %{
                "protocol" => "lldp",
                "remote_chassis_id_kind" => "mac_address",
                "remote_chassis_id" => mac,
                "remote_port_id_kind" => "mac_address",
                "remote_port_id" => mac,
                "ttl_seconds" => ttl
              }
            ]
          }
        ],
        true
      )
  end
end
