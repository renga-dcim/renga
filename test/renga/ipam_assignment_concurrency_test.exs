defmodule Renga.IPAMAssignmentConcurrencyTest do
  @moduledoc """
  Assignment transactions lock the managed address (RFD 4, "Managed
  addresses and assignments"), so two operators assigning one ordinary
  address to different interfaces at once cannot both succeed.
  """
  use ExUnit.Case, async: false

  import Renga.AccountsFixtures
  import Renga.InventoryFixtures
  import Renga.TopologyFixtures

  alias Ecto.Adapters.SQL.Sandbox
  alias Renga.Accounts
  alias Renga.IPAM
  alias Renga.IPAM.IpAddressAssignment
  alias Renga.Repo

  test "concurrent assignments of an ordinary address allow only one interface" do
    with_ipam(fn scope ->
      {_host, ports} = device_fixture(scope, "server", "race-a", ~w(eth0))
      {_other, other_ports} = device_fixture(scope, "server", "race-b", ~w(eth0))
      {:ok, address} = IPAM.create_ip_address(scope, %{address: "192.0.2.77/24"})

      {first_task, release_first} =
        held_mutation(fn -> IPAM.assign_address(scope, address.id, ports["eth0"].id) end)

      assert_receive :mutation_ready, 1_000

      second_task =
        concurrent(fn -> IPAM.assign_address(scope, address.id, other_ports["eth0"].id) end)

      # The second waits on the address row the first holds.
      assert Task.yield(second_task, 200) == nil
      release_first.()

      assert {:ok, {:ok, _assigned}} = Task.await(first_task)
      assert {:error, %Ecto.Changeset{} = changeset} = Task.await(second_task)
      assert {"is not available" <> _, _} = changeset.errors[:interface_id]

      assert [%{interface_id: interface_id}] = Repo.all(IpAddressAssignment)
      assert interface_id == ports["eth0"].id
    end)
  end

  defp held_mutation(mutation) do
    test_process = self()

    task =
      concurrent(fn ->
        Repo.transaction(fn ->
          result = mutation.()
          send(test_process, :mutation_ready)

          receive do
            :release_mutation -> result
          end
        end)
      end)

    {task, fn -> send(task.pid, :release_mutation) end}
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

  defp with_ipam(fun) do
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
