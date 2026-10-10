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
  import Renga.MutationRace, only: [race: 2]

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

  test "IPv6 allocations race safely, without enumerating the space" do
    with_ipam(fn scope, other ->
      site = prefix_fixture(scope, "2001:db8::/48", %{status: "container"})

      assert {{:ok, first}, {:ok, second}} =
               race(fn -> IPAM.allocate_prefix(scope, site, 64) end, fn ->
                 IPAM.allocate_prefix(other, site, 64)
               end)

      assert {Cidr.format(first.prefix), Cidr.format(second.prefix)} ==
               {"2001:db8::/64", "2001:db8:0:1::/64"}

      # The subnet-router anycast ::0 is never handed out.
      lan = first

      assert {{:ok, first_host}, {:ok, second_host}} =
               race(fn -> IPAM.allocate_address(scope, lan) end, fn ->
                 IPAM.allocate_address(other, lan)
               end)

      assert {Cidr.format(first_host.address), Cidr.format(second_host.address)} ==
               {"2001:db8::1/64", "2001:db8::2/64"}
    end)
  end

  test "allocations in a VRF and the global table take space in their own table" do
    with_ipam(fn scope, other ->
      blue = vrf_fixture(scope, "blue")
      global = prefix_fixture(scope, "10.0.0.0/16", %{status: "container"})
      in_blue = prefix_fixture(scope, "10.0.0.0/16", %{status: "container", vrf_id: blue.id})
      prefix_fixture(scope, "10.0.0.0/24")

      # Different tables still serialize on the organization lock, and the
      # global /24 does not occupy blue.
      assert {{:ok, blue_child}, {:ok, global_child}} =
               race(fn -> IPAM.allocate_prefix(scope, in_blue, 24) end, fn ->
                 IPAM.allocate_prefix(other, global, 24)
               end)

      assert {Cidr.format(blue_child.prefix), blue_child.vrf_id} == {"10.0.0.0/24", blue.id}
      assert {Cidr.format(global_child.prefix), global_child.vrf_id} == {"10.0.1.0/24", nil}

      # Two allocations in blue still take different space.
      assert {{:ok, first}, {:ok, second}} =
               race(fn -> IPAM.allocate_prefix(scope, in_blue, 24) end, fn ->
                 IPAM.allocate_prefix(other, in_blue, 24)
               end)

      assert {Cidr.format(first.prefix), Cidr.format(second.prefix)} ==
               {"10.0.1.0/24", "10.0.2.0/24"}
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
