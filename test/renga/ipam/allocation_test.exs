defmodule Renga.IPAM.AllocationTest do
  @moduledoc """
  "Next free" allocation (RFD 4, "Addressing plan and allocation"): the
  first child prefix of a length, or the first host of a leaf, that known
  inventory leaves free in the parent's routing table, recorded by owners
  and admins with an audit trail.
  """
  use Renga.DataCase, async: true

  import Renga.AccountsFixtures
  import Renga.InventoryFixtures
  import Renga.TopologyFixtures

  alias Renga.Accounts
  alias Renga.Inventory
  alias Renga.Inventory.ChangeEvent
  alias Renga.IPAM
  alias Renga.IPAM.Cidr

  setup do
    organization = organization_fixture()
    admin = scope_for(organization, "admin")
    member = scope_for(organization, "member")
    {:ok, agent} = Inventory.create_source(admin, %{kind: "host_agent", name: "agent"})
    %{admin: admin, member: member, agent: agent}
  end

  test "the next free child prefix skips children and every occupied host", context do
    parent = prefix_fixture(context.admin, "10.0.0.0/16", %{status: "container"})
    prefix_fixture(context.admin, "10.0.0.0/24")
    {:ok, _} = IPAM.create_ip_address(context.admin, %{address: "10.0.1.9/24"})

    # Observed hosts occupy space in their own namespace: 10.0.2.x is global,
    # 10.0.4.x is in blue, and 10.0.3.x is on an unmapped domain, which
    # could be anywhere.
    vrf_fixture(context.admin, "blue")

    report(context, [
      {"eth0", "10.0.2.7/24", :absent},
      {"eth1", "10.0.3.7/24", %{"key" => "lab"}},
      {"eth2", "10.0.4.7/24", %{"key" => "blue"}}
    ])

    assert {:ok, preview} = IPAM.next_free_prefix(context.admin, parent, 24)
    assert Cidr.format(preview) == "10.0.4.0/24"

    assert {:ok, allocated} =
             IPAM.allocate_prefix(context.admin, parent, 24, %{
               "status" => "reserved",
               "description" => "Voice"
             })

    assert Cidr.format(allocated.prefix) == "10.0.4.0/24"

    assert {allocated.status, allocated.description, allocated.vrf_id} ==
             {"reserved", "Voice", nil}

    assert Repo.get_by!(ChangeEvent, resource_id: allocated.resource_id, kind: "created").new_value ==
             %{"value" => "10.0.4.0/24"}

    # The next one goes past it.
    assert {:ok, next} = IPAM.allocate_prefix(context.admin, parent, 24)
    assert Cidr.format(next.prefix) == "10.0.5.0/24"
  end

  test "a VRF parent allocates in its own routing table", context do
    blue = vrf_fixture(context.admin, "blue")
    parent = prefix_fixture(context.admin, "10.0.0.0/16", %{vrf_id: blue.id})
    prefix_fixture(context.admin, "10.0.0.0/24")
    report(context, [{"eth0", "10.0.1.7/24", %{"key" => "blue"}}])

    # The global /24 is another table's, but blue's own observed host counts.
    assert {:ok, allocated} = IPAM.allocate_prefix(context.admin, parent, 24)
    assert Cidr.format(allocated.prefix) == "10.0.0.0/24"
    assert allocated.vrf_id == blue.id

    assert {:ok, next} = IPAM.allocate_prefix(context.admin, parent, 24)
    assert Cidr.format(next.prefix) == "10.0.2.0/24"
  end

  test "the next free host skips non-assignable, managed, and observed addresses", context do
    lan = prefix_fixture(context.admin, "192.0.2.0/29")
    {:ok, reserved} = IPAM.create_ip_address(context.admin, %{address: "192.0.2.1/29"})
    report(context, [{"eth0", "192.0.2.2/29", :absent}])

    assert {:ok, preview} = IPAM.next_free_host(context.admin, lan)
    assert Cidr.format(preview) == "192.0.2.3/29"

    assert {:ok, address} =
             IPAM.allocate_address(context.admin, lan, %{dns_name: "web-03.example.net"})

    assert Cidr.format(address.address) == "192.0.2.3/29"
    assert {address.allocation_state, address.dns_name} == {"allocated", "web-03.example.net"}

    # A released address frees its host, and allocation reuses its record.
    {:ok, _} = IPAM.release_address(context.admin, reserved.id)

    assert {:ok, again} =
             IPAM.allocate_address(context.admin, lan, %{allocation_state: "reserved"})

    assert again.id == reserved.id
    assert again.allocation_state == "reserved"

    for _ <- 4..6, do: {:ok, _} = IPAM.allocate_address(context.admin, lan)
    assert {:error, :full} = IPAM.allocate_address(context.admin, lan)
    assert {:error, :full} = IPAM.next_free_host(context.admin, lan)
  end

  test "allocation refuses what it cannot do", context do
    parent = prefix_fixture(context.admin, "10.0.0.0/24")
    prefix_fixture(context.admin, "10.0.0.0/25")
    prefix_fixture(context.admin, "10.0.0.128/25")

    assert {:error, :full} = IPAM.allocate_prefix(context.admin, parent, 25)

    # Two /25s cover the /24, so no longer block is free either.
    assert {:error, :full} = IPAM.next_free_prefix(context.admin, parent, 26)

    for length <- [24, 8, 33, "25"] do
      assert {:error, :invalid_length} = IPAM.next_free_prefix(context.admin, parent, length)
      assert {:error, :invalid_length} = IPAM.allocate_prefix(context.admin, parent, length)
    end

    # A prefix with children hands out space as prefixes, not hosts.
    assert {:error, :has_children} = IPAM.next_free_host(context.admin, parent)
    assert {:error, :has_children} = IPAM.allocate_address(context.admin, parent)

    leaf = prefix_fixture(context.admin, "10.1.0.0/24")
    assert {:error, :forbidden} = IPAM.allocate_prefix(context.member, leaf, 25)
    assert {:error, :forbidden} = IPAM.allocate_address(context.member, leaf)

    assert {:error, %Ecto.Changeset{}} =
             IPAM.allocate_address(context.admin, leaf, %{allocation_state: "lost"})

    assert {:error, %Ecto.Changeset{}} =
             IPAM.allocate_prefix(context.admin, leaf, 25, %{status: "lost"})

    assert IPAM.list_ip_addresses(context.admin) == []
  end

  # Reports one server's interfaces with an address each and an optional
  # routing-domain claim (`:absent` leaves it out).
  defp report(context, interfaces) do
    interfaces =
      Enum.map(interfaces, fn {name, address, claim} ->
        interface = %{"name" => name, "addresses" => [address]}
        if claim == :absent, do: interface, else: Map.put(interface, "routing_domain", claim)
      end)

    {:ok, observation} =
      Inventory.create_observation(context.admin, context.agent.id, %{
        idempotency_key: "allocation-#{System.unique_integer([:positive])}",
        observed_at: ~U[2026-08-01 12:00:00Z],
        payload: %{
          "resources" => [
            %{
              "kind" => "server",
              "identifiers" => %{"machine_id" => "router-1"},
              "interfaces" => interfaces
            }
          ]
        }
      })

    {:ok, _resource, _created?} = Inventory.reconcile_observation(context.admin, observation.id)
  end

  defp scope_for(organization, role) do
    user = user_fixture()
    organization_membership_fixture(user, organization, %{role: role})
    Accounts.scope_for_user(user, organization.id)
  end
end
