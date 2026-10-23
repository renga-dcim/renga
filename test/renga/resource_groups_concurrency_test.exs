defmodule Renga.ResourceGroupsConcurrencyTest do
  @moduledoc """
  Writes that can change effective group membership serialize on the
  organization lock and the group-projection lock (RFD 18), so concurrent
  membership and set changes cannot together put a resource in two groups of
  an exclusive set.
  """
  use ExUnit.Case, async: false

  import Renga.AccountsFixtures
  import Renga.InventoryFixtures
  import Renga.MutationRace, only: [race: 2]

  import Ecto.Query, only: [where: 3, select: 3]

  alias Ecto.Adapters.SQL.Sandbox
  alias Renga.Accounts
  alias Renga.Inventory
  alias Renga.Repo
  alias Renga.ResourceGroups
  alias Renga.ResourceGroups.Membership

  test "concurrent adds to two groups of an exclusive set allow only one" do
    with_admins(fn scope, other ->
      {:ok, web} = Inventory.create_resource(scope, %{kind: "server", name: "web-01"})
      {:ok, set} = ResourceGroups.create_group_set(scope, %{name: "Environment", exclusive: true})

      {:ok, production} =
        ResourceGroups.create_group(scope, %{name: "Production", group_set_id: set.id})

      {:ok, staging} =
        ResourceGroups.create_group(scope, %{name: "Staging", group_set_id: set.id})

      assert {{:ok, 1}, {:error, {:exclusive_conflict, [_conflict]}}} =
               race(fn -> ResourceGroups.add_members(scope, production, [web.id]) end, fn ->
                 ResourceGroups.add_members(other, staging, [web.id])
               end)

      assert web.id |> trusted_groups() == [production.id]
    end)
  end

  test "making a set exclusive while a second membership lands refuses one of them" do
    with_admins(fn scope, other ->
      {:ok, web} = Inventory.create_resource(scope, %{kind: "server", name: "web-01"})
      {:ok, set} = ResourceGroups.create_group_set(scope, %{name: "Customer"})
      {:ok, acme} = ResourceGroups.create_group(scope, %{name: "Acme", group_set_id: set.id})
      {:ok, globex} = ResourceGroups.create_group(scope, %{name: "Globex", group_set_id: set.id})
      {:ok, 1} = ResourceGroups.add_members(scope, acme, [web.id])

      assert {{:ok, 1}, {:error, {:exclusive_conflict, _conflicts}}} =
               race(fn -> ResourceGroups.add_members(scope, globex, [web.id]) end, fn ->
                 ResourceGroups.update_group_set(other, set, %{exclusive: true})
               end)

      refute Repo.reload!(set).exclusive
    end)
  end

  defp trusted_groups(resource_id) do
    Membership
    |> where(
      [membership],
      membership.resource_id == ^resource_id and membership.view == "trusted"
    )
    |> select([membership], membership.group_id)
    |> Repo.all()
  end

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
end
