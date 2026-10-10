defmodule Renga.IPAM.AddressingPlanTest do
  @moduledoc """
  The organization's addressing plan (RFD 4, Phase 7): per-family planning
  levels that owners and admins manage, and that decide the level every
  container's usage and child-space map count in.
  """
  use Renga.DataCase, async: true

  import Renga.AccountsFixtures
  import Renga.InventoryFixtures
  import Renga.TopologyFixtures

  alias Renga.Accounts
  alias Renga.IPAM

  setup do
    organization = organization_fixture()
    admin = scope_for(organization, "admin")
    member = scope_for(organization, "member")
    %{organization: organization, admin: admin, member: member}
  end

  test "owners and admins manage levels; a family holds each length once", context do
    assert {:ok, hall} =
             IPAM.create_plan_level(context.admin, %{
               family: "ipv6",
               prefix_length: 56,
               name: " hall "
             })

    assert hall.name == "hall"

    {:ok, _site} =
      IPAM.create_plan_level(context.admin, %{family: "ipv6", prefix_length: 48, name: "site"})

    {:ok, _rack} =
      IPAM.create_plan_level(context.admin, %{family: "ipv4", prefix_length: 24, name: "rack"})

    assert Enum.map(IPAM.list_plan_levels(context.admin), &{&1.family, &1.prefix_length}) ==
             [{"ipv4", 24}, {"ipv6", 48}, {"ipv6", 56}]

    assert {:error, changeset} =
             IPAM.create_plan_level(context.admin, %{family: "ipv6", prefix_length: 56, name: "x"})

    assert "is already a level of this family's plan" in errors_on(changeset).prefix_length

    # A level is a child length: neither the whole space nor a host.
    for {family, length} <- [{"ipv4", 32}, {"ipv4", 0}, {"ipv6", 128}] do
      assert {:error, changeset} =
               IPAM.create_plan_level(context.admin, %{
                 family: family,
                 prefix_length: length,
                 name: "x"
               })

      assert [_] = errors_on(changeset).prefix_length
    end

    assert {:error, :forbidden} =
             IPAM.create_plan_level(context.member, %{
               family: "ipv6",
               prefix_length: 64,
               name: "VLAN"
             })

    assert {:error, :forbidden} = IPAM.delete_plan_level(context.member, hall.id)
    assert {:ok, _} = IPAM.delete_plan_level(context.admin, hall.id)
    assert length(IPAM.list_plan_levels(context.member)) == 2

    # Plans are per organization.
    other = scope_for(organization_fixture(), "admin")
    assert IPAM.list_plan_levels(other) == []

    assert_raise Ecto.NoResultsError, fn ->
      IPAM.delete_plan_level(other, List.first(IPAM.list_plan_levels(context.admin)).id)
    end
  end

  test "containers count and map their space at the planned level", context do
    site = prefix_fixture(context.admin, "2001:db8:a::/48", %{status: "container"})
    prefix_fixture(context.admin, "2001:db8:a:1::/64")
    prefix_fixture(context.admin, "2001:db8:a:2::/64")

    usage = fn ->
      %{ipv6: rows} = IPAM.list_prefix_rows(context.admin, nil)
      row = Enum.find(rows, &(&1.node.prefix.id == site.id))
      Map.take(row.usage, [:allocated, :total, :level, :level_name])
    end

    # Without a plan the level follows its /64 children.
    assert usage.() == %{allocated: 2, total: 65_536, level: 64, level_name: nil}

    {:ok, _} =
      IPAM.create_plan_level(context.admin, %{family: "ipv6", prefix_length: 56, name: "hall"})

    # Both /64s are in the first hall.
    assert usage.() == %{allocated: 1, total: 256, level: 56, level_name: "hall"}

    %{space: space} = IPAM.prefix_view(context.admin, site)

    assert {space.level, space.level_name, space.allocated, length(space.cells)} ==
             {56, "hall", 1, 256}
  end

  defp scope_for(organization, role) do
    user = user_fixture()
    organization_membership_fixture(user, organization, %{role: role})
    Accounts.scope_for_user(user, organization.id)
  end
end
