defmodule Renga.IPAMAllocationConcurrencyTest do
  @moduledoc """
  Allocation is serialized with every managed write that changes what is
  free (RFD 4, "Addressing plan and allocation"): it takes the organization
  lock first, as prefix and address writes do, and re-reads the space in
  the same transaction it records the allocation in.

  Each race holds one write's transaction open, starts a competing one,
  shows it waits, and then that it took different space.
  """
  use ExUnit.Case, async: false

  import Renga.AccountsFixtures
  import Renga.InventoryFixtures
  import Renga.TopologyFixtures

  alias Ecto.Adapters.SQL.Sandbox
  alias Renga.Accounts
  alias Renga.IPAM
  alias Renga.IPAM.Cidr
  alias Renga.Repo

  test "concurrent allocations never take the same prefix or host" do
    with_ipam(fn scope, other ->
      parent = prefix_fixture(scope, "10.0.0.0/16", %{status: "container"})

      assert {{:ok, first}, {:ok, second}} =
               race(fn -> IPAM.allocate_prefix(scope, parent, 24) end, fn ->
                 IPAM.allocate_prefix(other, parent, 24)
               end)

      assert {Cidr.format(first.prefix), Cidr.format(second.prefix)} ==
               {"10.0.0.0/24", "10.0.1.0/24"}

      lan = prefix_fixture(scope, "192.0.2.0/24")

      assert {{:ok, first}, {:ok, second}} =
               race(fn -> IPAM.allocate_address(scope, lan) end, fn ->
                 IPAM.allocate_address(other, lan)
               end)

      assert {Cidr.format(first.address), Cidr.format(second.address)} ==
               {"192.0.2.1/24", "192.0.2.2/24"}
    end)
  end

  test "an allocation waits for a manual write and avoids its space" do
    with_ipam(fn scope, other ->
      parent = prefix_fixture(scope, "10.0.0.0/16", %{status: "container"})

      assert {{:ok, _manual}, {:ok, allocated}} =
               race(fn -> IPAM.create_prefix(scope, %{prefix: "10.0.0.0/24"}) end, fn ->
                 IPAM.allocate_prefix(other, parent, 24)
               end)

      assert Cidr.format(allocated.prefix) == "10.0.1.0/24"

      lan = prefix_fixture(scope, "192.0.2.0/24")

      assert {{:ok, _reserved}, {:ok, allocated}} =
               race(fn -> IPAM.create_ip_address(scope, %{address: "192.0.2.1/24"}) end, fn ->
                 IPAM.allocate_address(other, lan)
               end)

      assert Cidr.format(allocated.address) == "192.0.2.2/24"
    end)
  end

  test "a manual write waits for an allocation and cannot duplicate it" do
    with_ipam(fn scope, other ->
      parent = prefix_fixture(scope, "10.0.0.0/16", %{status: "container"})

      assert {{:ok, allocated}, {:error, %Ecto.Changeset{} = changeset}} =
               race(fn -> IPAM.allocate_prefix(scope, parent, 24) end, fn ->
                 IPAM.create_prefix(other, %{prefix: "10.0.0.0/24"})
               end)

      assert Cidr.format(allocated.prefix) == "10.0.0.0/24"
      assert {"already exists in this routing table", _} = changeset.errors[:prefix]
    end)
  end

  test "an allocation sees a prefix resized while it waited" do
    with_ipam(fn scope, other ->
      parent = prefix_fixture(scope, "10.0.0.0/16", %{status: "container"})
      child = prefix_fixture(scope, "10.0.0.0/24")

      # The child grows to a /23 first; the allocation must not hand out
      # 10.0.1.0/24, which the resize just covered.
      assert {{:ok, resized}, {:ok, allocated}} =
               race(fn -> IPAM.update_prefix(scope, child, %{prefix: "10.0.0.0/23"}) end, fn ->
                 IPAM.allocate_prefix(other, parent, 24)
               end)

      assert Cidr.format(resized.prefix) == "10.0.0.0/23"
      assert Cidr.format(allocated.prefix) == "10.0.2.0/24"

      # A parent shrunk meanwhile allocates inside its new bounds only.
      lan = prefix_fixture(scope, "192.0.2.0/24")
      {:ok, _} = IPAM.create_ip_address(scope, %{address: "192.0.2.1/24"})
      {:ok, _} = IPAM.create_ip_address(scope, %{address: "192.0.2.2/24"})

      assert {{:ok, _shrunk}, {:error, :full}} =
               race(fn -> IPAM.update_prefix(scope, lan, %{prefix: "192.0.2.0/30"}) end, fn ->
                 IPAM.allocate_address(other, lan)
               end)
    end)
  end

  # Runs `held` in a transaction kept open until `competing` has had time to
  # block on it, then releases it. Returns both results.
  defp race(held, competing) do
    {held_task, release} = held_mutation(held)
    assert_receive :mutation_ready, 1_000

    competing_task = concurrent(competing)

    # The competing write waits on the organization lock the first holds.
    assert Task.yield(competing_task, 200) == nil
    release.()

    {:ok, held_result} = Task.await(held_task)
    {held_result, Task.await(competing_task)}
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

  # Two admins, so each side of a race locks its own membership and only
  # the organization lock can serialize them.
  defp with_ipam(fun) do
    :ok = Sandbox.checkout(Repo, sandbox: false)
    organization = organization_fixture()
    users = for _ <- 1..2, do: user_fixture()

    [scope, other] =
      Enum.map(users, fn user ->
        organization_membership_fixture(user, organization, %{role: "admin"})
        Accounts.scope_for_user(user, organization.id)
      end)

    try do
      fun.(scope, other)
    after
      Repo.delete!(organization)
      Enum.each(users, &Repo.delete!/1)
      Sandbox.checkin(Repo)
    end
  end
end
