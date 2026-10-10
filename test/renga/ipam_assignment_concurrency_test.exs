defmodule Renga.IPAMAssignmentConcurrencyTest do
  @moduledoc """
  Managed writes serialize assignments and role changes (RFD 4, "Managed
  addresses and assignments"), so two operators assigning one ordinary
  address to different interfaces at once cannot both succeed, in either
  family, while a shared role takes both. A role change racing an
  assignment never leaves an ordinary address on two interfaces.
  """
  use ExUnit.Case, async: false

  import Renga.AccountsFixtures
  import Renga.InventoryFixtures
  import Renga.TopologyFixtures
  import Renga.MutationRace, only: [race: 2]

  import Ecto.Query, only: [where: 2]

  alias Ecto.Adapters.SQL.Sandbox
  alias Renga.Accounts
  alias Renga.IPAM
  alias Renga.IPAM.IpAddress
  alias Renga.IPAM.IpAddressAssignment
  alias Renga.Repo

  test "concurrent assignments of an ordinary address allow only one interface" do
    with_ipam(fn scope ->
      {_host, ports} = device_fixture(scope, "server", "race-a", ~w(eth0))
      {_other, other_ports} = device_fixture(scope, "server", "race-b", ~w(eth0))
      {:ok, address} = IPAM.create_ip_address(scope, %{address: "192.0.2.77/24"})

      assert {{:ok, _assigned}, {:error, %Ecto.Changeset{} = changeset}} =
               race(fn -> IPAM.assign_address(scope, address.id, ports["eth0"].id) end, fn ->
                 IPAM.assign_address(scope, address.id, other_ports["eth0"].id)
               end)

      assert {"is not available" <> _, _} = changeset.errors[:interface_id]

      assert [%{interface_id: interface_id}] = Repo.all(IpAddressAssignment)
      assert interface_id == ports["eth0"].id
    end)
  end

  test "an ordinary IPv6 address goes to one interface; a VIP to both" do
    with_admins(fn scope, other ->
      {_host, ports} = device_fixture(scope, "server", "race6-a", ~w(eth0))
      {_other, other_ports} = device_fixture(scope, "server", "race6-b", ~w(eth0))
      {:ok, ordinary} = IPAM.create_ip_address(scope, %{address: "2001:db8::77/64"})

      assert {{:ok, _assigned}, {:error, %Ecto.Changeset{} = changeset}} =
               race(fn -> IPAM.assign_address(scope, ordinary.id, ports["eth0"].id) end, fn ->
                 IPAM.assign_address(other, ordinary.id, other_ports["eth0"].id)
               end)

      assert {"is not available" <> _, _} = changeset.errors[:interface_id]

      {:ok, vip} = IPAM.create_ip_address(scope, %{address: "2001:db8::80/64", role: "vip"})

      assert {{:ok, _first}, {:ok, second}} =
               race(fn -> IPAM.assign_address(scope, vip.id, ports["eth0"].id) end, fn ->
                 IPAM.assign_address(other, vip.id, other_ports["eth0"].id)
               end)

      assert length(second.assignments) == 2
    end)
  end

  test "a role change racing a second assignment never shares an ordinary address" do
    with_admins(fn scope, other ->
      {_host, ports} = device_fixture(scope, "server", "role-a", ~w(eth0))
      {_other, other_ports} = device_fixture(scope, "server", "role-b", ~w(eth0))

      # The second assignment wins the lock; the address is then shared, so
      # it may not become ordinary.
      {:ok, vip} = IPAM.create_ip_address(scope, %{address: "192.0.2.80/24", role: "vip"})
      {:ok, vip} = IPAM.assign_address(scope, vip.id, ports["eth0"].id)

      assert {{:ok, shared}, {:error, %Ecto.Changeset{} = changeset}} =
               race(fn -> IPAM.assign_address(scope, vip.id, other_ports["eth0"].id) end, fn ->
                 IPAM.update_ip_address(other, vip, %{role: "ordinary"})
               end)

      assert length(shared.assignments) == 2
      assert {"is shared by 2 interfaces" <> _, _} = changeset.errors[:role]
      assert Repo.get!(IpAddress, vip.id).role == "vip"

      # The role change wins the lock; the address is then ordinary, so it
      # may not take a second interface.
      {:ok, anycast} =
        IPAM.create_ip_address(scope, %{address: "192.0.2.81/24", role: "anycast"})

      {:ok, anycast} = IPAM.assign_address(scope, anycast.id, ports["eth0"].id)

      assert {{:ok, %{role: "ordinary"}}, {:error, %Ecto.Changeset{} = changeset}} =
               race(fn -> IPAM.update_ip_address(scope, anycast, %{role: "ordinary"}) end, fn ->
                 IPAM.assign_address(other, anycast.id, other_ports["eth0"].id)
               end)

      assert {"is not available" <> _, _} = changeset.errors[:interface_id]
      assert Repo.aggregate(where(IpAddressAssignment, ip_address_id: ^anycast.id), :count) == 1
    end)
  end

  # Two admins, so each side of a race locks its own membership.
  defp with_admins(fun) do
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
