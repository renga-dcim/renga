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
