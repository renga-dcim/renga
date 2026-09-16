defmodule Renga.TopologyConcurrencyTest do
  use ExUnit.Case, async: false

  import Renga.InventoryFixtures

  alias Ecto.Adapters.SQL.Sandbox
  alias Renga.Accounts
  alias Renga.Inventory
  alias Renga.Repo
  alias Renga.Topology

  @timeout 5_000

  test "a concurrent range change cannot admit a VLAN that it strands" do
    with_topology(fn scope, suffix ->
      {:ok, group} =
        Topology.create_vlan_group(
          scope,
          %{name: "Concurrent namespace #{suffix}", lifecycle_state: "active"},
          %{slug: "concurrent-namespace-#{suffix}"},
          [%{start_vid: 1, end_vid: 200}]
        )

      test_process = self()

      range_task =
        concurrent_task(fn ->
          Repo.transaction(fn ->
            result =
              Topology.replace_vlan_group_ranges(scope, group, [
                %{start_vid: 101, end_vid: 200}
              ])

            send(test_process, :range_change_ready)

            receive do
              :release_range_change -> result
            end
          end)
        end)

      assert_receive :range_change_ready, @timeout

      vlan_task =
        concurrent_task(fn ->
          Topology.create_vlan(
            scope,
            %{},
            %{vlan_group_id: group.id, vid: 50, name: "Stranded VLAN"}
          )
        end)

      assert Task.yield(vlan_task, 200) == nil
      send(range_task.pid, :release_range_change)

      assert {:ok, {:ok, _updated_group}} = Task.await(range_task, @timeout)
      assert {:error, :vlan_out_of_range} = Task.await(vlan_task, @timeout)
      assert Topology.list_vlans(scope, group.id) == []
    end)
  end

  test "competing desired untagged assignments preserve the single-untagged invariant" do
    {organization, user, scope, interface, [first_vlan, second_vlan]} = context(2)

    results =
      concurrently([
        fn ->
          Topology.put_desired_interface_vlan_assignment(scope, interface.id, first_vlan.id, %{
            tagging_mode: "untagged"
          })
        end,
        fn ->
          Topology.put_desired_interface_vlan_assignment(scope, interface.id, second_vlan.id, %{
            tagging_mode: "untagged"
          })
        end
      ])

    try do
      assert Enum.count(results, &match?({:ok, _}, &1)) == 1
      assert Enum.count(results, &match?({:error, %Ecto.Changeset{}}, &1)) == 1
      assert [_assignment] = Topology.list_desired_interface_vlan_assignments(scope, interface.id)
    after
      Repo.delete!(organization)
      Repo.delete!(user)
      Sandbox.checkin(Repo)
    end
  end

  test "competing access-mode and tagged-assignment writes cannot commit incompatible state" do
    {organization, user, scope, interface, [vlan]} = context(1)

    results =
      concurrently([
        fn ->
          Topology.put_desired_interface_vlan_mode(scope, interface.id, %{mode: "access"})
        end,
        fn ->
          Topology.put_desired_interface_vlan_assignment(scope, interface.id, vlan.id, %{
            tagging_mode: "tagged"
          })
        end
      ])

    try do
      assert Enum.count(results, &match?({:ok, _}, &1)) == 1
      assert Enum.count(results, &match?({:error, :invalid_interface_vlan_mode}, &1)) == 1

      mode = Topology.get_desired_interface_vlan_mode(scope, interface.id)
      assignments = Topology.list_desired_interface_vlan_assignments(scope, interface.id)
      refute mode && mode.mode == "access" && assignments != []
    after
      Repo.delete!(organization)
      Repo.delete!(user)
      Sandbox.checkin(Repo)
    end
  end

  test "concurrent reciprocal neighbor reports converge on one canonical adjacency" do
    with_topology(fn scope, suffix ->
      {:ok, first_resource} =
        Inventory.create_resource(scope, %{
          kind: "server",
          name: "neighbor-race-first-#{suffix}",
          lifecycle_state: "active"
        })

      {:ok, second_resource} =
        Inventory.create_resource(scope, %{
          kind: "server",
          name: "neighbor-race-second-#{suffix}",
          lifecycle_state: "active"
        })

      {:ok, first_interface} =
        Inventory.create_interface(scope, first_resource.id, %{name: "eth0"})

      {:ok, second_interface} =
        Inventory.create_interface(scope, second_resource.id, %{name: "eth0"})

      {:ok, first_source} =
        Inventory.create_source(scope, %{kind: "manual", name: "neighbor-race-first-#{suffix}"})

      {:ok, second_source} =
        Inventory.create_source(scope, %{kind: "manual", name: "neighbor-race-second-#{suffix}"})

      {:ok, first_observation} =
        Inventory.create_observation(scope, first_source.id, %{
          idempotency_key: "neighbor-race-first-#{suffix}",
          observed_at: ~U[2099-09-11 00:00:00Z],
          payload: %{}
        })

      {:ok, second_observation} =
        Inventory.create_observation(scope, second_source.id, %{
          idempotency_key: "neighbor-race-second-#{suffix}",
          observed_at: ~U[2099-09-11 00:00:00Z],
          payload: %{}
        })

      results =
        concurrently([
          fn ->
            reconcile_neighbor(
              scope,
              first_source,
              first_observation,
              first_resource,
              first_interface,
              second_resource,
              second_interface
            )
          end,
          fn ->
            reconcile_neighbor(
              scope,
              second_source,
              second_observation,
              second_resource,
              second_interface,
              first_resource,
              first_interface
            )
          end
        ])

      assert Enum.all?(results, &match?({:ok, [_]}, &1))
      assert [%{confidence: "reciprocal"}] = Topology.list_current_interface_adjacencies(scope)
    end)
  end

  test "concurrent direct interface creates serialize before foreign-key writes" do
    with_topology(fn scope, suffix ->
      {:ok, local_resource} =
        Inventory.create_resource(scope, %{
          kind: "server",
          name: "neighbor-create-local-#{suffix}",
          lifecycle_state: "active"
        })

      {:ok, remote_resource} =
        Inventory.create_resource(scope, %{
          kind: "server",
          name: "neighbor-create-remote-#{suffix}",
          lifecycle_state: "active"
        })

      {:ok, local_interface} =
        Inventory.create_interface(scope, local_resource.id, %{name: "eth0"})

      {:ok, remote_interface} =
        Inventory.create_interface(scope, remote_resource.id, %{name: "swp1"})

      {:ok, source} =
        Inventory.create_source(scope, %{kind: "manual", name: "neighbor-create-#{suffix}"})

      {:ok, observation} =
        Inventory.create_observation(scope, source.id, %{
          idempotency_key: "neighbor-create-#{suffix}",
          observed_at: ~U[2099-09-11 00:10:00Z],
          payload: %{}
        })

      assert {:ok, [_evidence]} =
               reconcile_neighbor(
                 scope,
                 source,
                 observation,
                 local_resource,
                 local_interface,
                 remote_resource,
                 remote_interface
               )

      resources =
        for index <- 1..2 do
          {:ok, resource} =
            Inventory.create_resource(scope, %{
              kind: "server",
              name: "neighbor-create-target-#{index}-#{suffix}",
              lifecycle_state: "active"
            })

          resource
        end

      results =
        resources
        |> Enum.with_index(1)
        |> Enum.map(fn {resource, index} ->
          fn -> Inventory.create_interface(scope, resource.id, %{name: "eth#{index}"}) end
        end)
        |> concurrently()

      assert Enum.all?(results, &match?({:ok, _interface}, &1))
    end)
  end

  test "inventory serialization locks the organization row before its advisory lock" do
    with_topology(fn scope, _suffix ->
      test_process = self()

      advisory_blocker =
        concurrent_task(fn ->
          Repo.transaction(fn ->
            Repo.query!("SELECT pg_advisory_xact_lock(hashtextextended($1, 0))", [
              scope.organization_id
            ])

            send(test_process, :advisory_locked)

            receive do
              :release_advisory -> :ok
            after
              @timeout -> raise "advisory lock was not released"
            end
          end)
        end)

      assert_receive :advisory_locked, @timeout

      organization_lock =
        concurrent_task(fn ->
          backend_pid =
            Repo.query!("SELECT pg_backend_pid()").rows |> List.first() |> List.first()

          send(test_process, {:organization_lock_backend, backend_pid})
          Repo.transaction(fn -> Inventory.lock_organization!(scope.organization_id) end)
        end)

      assert_receive {:organization_lock_backend, backend_pid}, @timeout
      await_backend_lock!(backend_pid, :advisory, @timeout)

      row_lock_result =
        try do
          Repo.query(
            "SELECT id FROM organizations WHERE id = $1::text::uuid FOR UPDATE NOWAIT",
            [scope.organization_id]
          )
        after
          send(advisory_blocker.pid, :release_advisory)
        end

      assert {:error, %Postgrex.Error{postgres: %{code: :lock_not_available}}} = row_lock_result
      assert {:ok, :ok} = Task.await(advisory_blocker, @timeout)
      assert {:ok, :ok} = Task.await(organization_lock, @timeout)
    end)
  end

  test "resource creation locks the organization before allocating a revision" do
    with_topology(fn scope, suffix ->
      test_process = self()

      row_blocker =
        concurrent_task(fn ->
          Repo.transaction(fn ->
            Repo.query!(
              "SELECT id FROM organizations WHERE id = $1::text::uuid FOR UPDATE",
              [scope.organization_id]
            )

            send(test_process, :organization_row_locked)

            receive do
              :release_organization_row -> :ok
            after
              @timeout -> raise "organization row lock was not released"
            end
          end)
        end)

      assert_receive :organization_row_locked, @timeout

      create_task =
        concurrent_task(fn ->
          backend_pid =
            Repo.query!("SELECT pg_backend_pid()").rows |> List.first() |> List.first()

          send(test_process, {:resource_create_backend, backend_pid})

          Inventory.create_resource(scope, %{
            kind: "server",
            name: "neighbor-lock-order-#{suffix}",
            lifecycle_state: "active"
          })
        end)

      assert_receive {:resource_create_backend, backend_pid}, @timeout
      await_backend_lock!(backend_pid, :row, @timeout)

      revision_lock_available =
        try do
          Repo.query!("SELECT pg_try_advisory_xact_lock($1)", [1_380_271_687])
        after
          send(row_blocker.pid, :release_organization_row)
        end

      assert %{rows: [[true]]} = revision_lock_available
      assert {:ok, :ok} = Task.await(row_blocker, @timeout)
      assert {:ok, _resource} = Task.await(create_task, @timeout)
    end)
  end

  defp context(vlan_count) do
    :ok = Sandbox.checkout(Repo, sandbox: false)
    suffix = System.unique_integer([:positive])
    organization = organization_fixture(%{slug: "topology-race-#{suffix}"})

    {:ok, user} =
      Accounts.register_user(%{
        email: "topology-race-#{suffix}-#{Ecto.UUID.generate()}@example.com"
      })

    organization_membership_fixture(user, organization, %{role: "admin"})
    scope = Accounts.scope_for_user(user, organization.id)

    {:ok, resource} =
      Inventory.create_resource(scope, %{
        kind: "server",
        name: "topology-race-server-#{suffix}",
        lifecycle_state: "active"
      })

    {:ok, interface} = Inventory.create_interface(scope, resource.id, %{name: "eth0"})

    {:ok, group} =
      Topology.create_vlan_group(
        scope,
        %{name: "Race group #{suffix}", lifecycle_state: "active"},
        %{slug: "race-group-#{suffix}", scope_kind: "global", status: "active"},
        [%{start_vid: 1, end_vid: 100}]
      )

    vlans =
      for vid <- 1..vlan_count do
        {:ok, vlan} =
          Topology.create_vlan(
            scope,
            %{lifecycle_state: "active"},
            %{vlan_group_id: group.id, vid: vid, name: "Race VLAN #{vid}", status: "active"}
          )

        vlan
      end

    {organization, user, scope, interface, vlans}
  end

  defp concurrently(functions) do
    parent = self()

    tasks =
      Enum.map(functions, fn function ->
        Task.async(fn ->
          :ok = Sandbox.checkout(Repo, sandbox: false)

          try do
            send(parent, {:ready, self()})

            receive do
              :go -> function.()
            after
              @timeout -> raise "concurrent topology test did not start"
            end
          after
            Sandbox.checkin(Repo)
          end
        end)
      end)

    Enum.each(tasks, fn _task ->
      assert_receive {:ready, pid}, @timeout
      assert pid in Enum.map(tasks, & &1.pid)
    end)

    Enum.each(tasks, &send(&1.pid, :go))
    Task.await_many(tasks, @timeout)
  end

  defp await_backend_lock!(backend_pid, lock_kind, timeout) do
    deadline = :erlang.monotonic_time(:millisecond) + timeout
    poll_backend_lock!(backend_pid, lock_kind, deadline)
  end

  defp poll_backend_lock!(backend_pid, lock_kind, deadline) do
    waiting? =
      case Repo.query!(
             "SELECT wait_event_type, wait_event FROM pg_stat_activity WHERE pid = $1",
             [backend_pid]
           ).rows do
        [["Lock", "advisory"]] -> lock_kind == :advisory
        [["Lock", _row_lock]] -> lock_kind == :row
        _not_waiting -> false
      end

    cond do
      waiting? ->
        :ok

      :erlang.monotonic_time(:millisecond) >= deadline ->
        flunk("backend #{backend_pid} did not wait on the expected #{lock_kind} lock")

      true ->
        Process.sleep(10)
        poll_backend_lock!(backend_pid, lock_kind, deadline)
    end
  end

  defp reconcile_neighbor(
         scope,
         source,
         observation,
         local_resource,
         local_interface,
         remote_resource,
         remote_interface
       ) do
    Topology.reconcile_interface_neighbors(
      scope,
      source,
      observation,
      local_resource.id,
      [
        %{
          "name" => local_interface.name,
          "neighbors" => [
            %{
              "protocol" => "lldp",
              "remote_chassis_id" => remote_resource.name,
              "remote_port_id" => remote_interface.name,
              "ttl_seconds" => 120,
              "metadata" => %{}
            }
          ]
        }
      ],
      true
    )
  end

  defp concurrent_task(function) do
    Task.async(fn ->
      :ok = Sandbox.checkout(Repo, sandbox: false)

      try do
        function.()
      after
        Sandbox.checkin(Repo)
      end
    end)
  end

  defp with_topology(function) do
    :ok = Sandbox.checkout(Repo, sandbox: false)
    suffix = "#{System.unique_integer([:positive])}-#{Ecto.UUID.generate()}"
    organization = organization_fixture(%{slug: "topology-range-race-#{suffix}"})
    {:ok, user} = Accounts.register_user(%{email: "topology-range-race-#{suffix}@example.com"})
    organization_membership_fixture(user, organization, %{role: "admin"})
    scope = Accounts.scope_for_user(user, organization.id)

    try do
      function.(scope, suffix)
    after
      Repo.delete!(organization)
      Repo.delete!(user)
      Sandbox.checkin(Repo)
    end
  end
end
