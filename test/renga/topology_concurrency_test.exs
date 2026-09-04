defmodule Renga.TopologyConcurrencyTest do
  use ExUnit.Case, async: false

  import Renga.AccountsFixtures
  import Renga.InventoryFixtures

  alias Ecto.Adapters.SQL.Sandbox
  alias Renga.Accounts
  alias Renga.Repo
  alias Renga.Topology

  test "a concurrent range change cannot admit a VLAN that it strands" do
    with_topology(fn scope ->
      {:ok, group} =
        Topology.create_vlan_group(
          scope,
          %{name: "Concurrent namespace", lifecycle_state: "active"},
          %{slug: "concurrent-namespace"},
          [%{start_vid: 1, end_vid: 200}]
        )

      test_process = self()

      range_task =
        concurrent(fn ->
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

      assert_receive :range_change_ready, 1_000

      vlan_task =
        concurrent(fn ->
          Topology.create_vlan(
            scope,
            %{},
            %{vlan_group_id: group.id, vid: 50, name: "Stranded VLAN"}
          )
        end)

      assert Task.yield(vlan_task, 200) == nil
      send(range_task.pid, :release_range_change)

      assert {:ok, {:ok, _updated_group}} = Task.await(range_task)
      assert {:error, :vlan_out_of_range} = Task.await(vlan_task)
      assert Topology.list_vlans(scope, group.id) == []
    end)
  end

  defp concurrent(fun) do
    Task.async(fn ->
      :ok = Sandbox.checkout(Repo, sandbox: false)

      try do
        fun.()
      after
        Sandbox.checkin(Repo)
      end
    end)
  end

  defp with_topology(fun) do
    :ok = Sandbox.checkout(Repo, sandbox: false)
    user = user_fixture()
    organization = organization_fixture()
    organization_membership_fixture(user, organization, %{role: "admin"})
    scope = Accounts.scope_for_user(user, organization.id)

    try do
      fun.(scope)
    after
      Repo.delete!(organization)
      Repo.delete!(user)
      Sandbox.checkin(Repo)
    end
  end
end
