defmodule Renga.IPAM.RoutingDomainsTest do
  @moduledoc """
  Routing-domain claims (RFD 4, Phase 6): collectors' interface claims are
  observation-linked evidence that newer reports supersede or withdraw, and
  each interface's current claim resolves to a VRF, the global table, or
  `unmapped` through explicit mappings, route distinguishers, VRF names,
  and the reserved `default` key, preferring authoritative sources.
  """
  use Renga.DataCase, async: true

  import Renga.AccountsFixtures
  import Renga.InventoryFixtures
  import Renga.TopologyFixtures

  alias Renga.Accounts
  alias Renga.Inventory
  alias Renga.IPAM.InterfaceRoutingDomain
  alias Renga.IPAM.RoutingDomainEvidence
  alias Renga.IPAM.RoutingDomains

  setup do
    organization = organization_fixture()
    user = user_fixture()
    organization_membership_fixture(user, organization, %{role: "admin"})
    scope = Accounts.scope_for_user(user, organization.id)
    {:ok, agent} = Inventory.create_source(scope, %{kind: "host_agent", name: "agent"})
    %{scope: scope, organization: organization, agent: agent}
  end

  test "a claim resolves by mapping, route distinguisher, name, or the default key", context do
    blue = vrf_fixture(context.scope, "blue")
    red = vrf_fixture(context.scope, "red", %{route_distinguisher: "65000:2"})

    report(context, context.agent, 1, %{
      "eth0" => %{"key" => "BLUE"},
      "eth1" => %{"key" => "tenant-red", "route_distinguisher" => "65000:2"},
      "eth2" => %{"key" => "default"},
      "eth3" => %{"key" => "lab"}
    })

    assert domains(context) == %{
             "eth0" => {"name", blue.id},
             "eth1" => {"route_distinguisher", red.id},
             "eth2" => {"default", nil},
             "eth3" => {"unmapped", nil}
           }

    # An explicit mapping wins over every automatic match, to a VRF or to
    # the global table, and removing it restores the automatic one.
    {:ok, lab} = RoutingDomains.put_mapping(context.scope, context.agent.id, "LAB", red.id)
    {:ok, _} = RoutingDomains.put_mapping(context.scope, context.agent.id, "blue", nil)

    assert %{"eth0" => {"mapping", nil}, "eth3" => {"mapping", red_id}} = domains(context)
    assert red_id == red.id

    {:ok, _} = RoutingDomains.delete_mapping(context.scope, lab.id)
    assert %{"eth3" => {"unmapped", nil}} = domains(context)
  end

  test "VRF changes re-resolve reported domains", context do
    report(context, context.agent, 1, %{"eth0" => %{"key" => "green"}})
    assert %{"eth0" => {"unmapped", nil}} = domains(context)

    green = vrf_fixture(context.scope, "green")
    assert %{"eth0" => {"name", green_id}} = domains(context)
    assert green_id == green.id

    {:ok, _} = Renga.IPAM.update_vrf(context.scope, green, %{name: "emerald"})
    assert %{"eth0" => {"unmapped", nil}} = domains(context)
  end

  test "newer reports replace and withdraw claims; older replays stay history", context do
    vrf_fixture(context.scope, "blue")
    vrf_fixture(context.scope, "red")
    first = report(context, context.agent, 1, %{"eth0" => %{"key" => "blue"}})
    report(context, context.agent, 2, %{"eth0" => %{"key" => "red"}})
    assert %{"eth0" => {"name", _}} = domains(context)
    assert active_keys(context) == ["red"]

    # Replaying the older report adds nothing and changes nothing.
    {:ok, _, _} = Inventory.reconcile_observation(context.scope, first.id)
    assert active_keys(context) == ["red"]

    # An absent field says nothing; null withdraws the claim, so the
    # interface is global again.
    report(context, context.agent, 3, %{"eth0" => :absent})
    assert active_keys(context) == ["red"]
    report(context, context.agent, 4, %{"eth0" => nil})
    assert domains(context) == %{}

    # A late report older than the withdrawal cannot revive a claim.
    report(context, context.agent, 3, %{"eth0" => %{"key" => "blue"}}, "late")
    assert domains(context) == %{}
    assert Repo.aggregate(RoutingDomainEvidence, :count) == 4
  end

  test "an authoritative source's claim wins over a newer one from another", context do
    {:ok, inventory} = Inventory.create_source(context.scope, %{kind: "vm_provider", name: "vms"})
    refute inventory.authoritative_routing_domains
    assert context.agent.authoritative_routing_domains

    blue = vrf_fixture(context.scope, "blue")
    red = vrf_fixture(context.scope, "red")
    report(context, context.agent, 1, %{"eth0" => %{"key" => "blue"}})
    report(context, inventory, 2, %{"eth0" => %{"key" => "red"}})

    assert %{"eth0" => {"name", blue_id}} = domains(context)
    assert blue_id == blue.id

    {:ok, _} = RoutingDomains.set_source_authority(context.scope, inventory.id, true)
    assert %{"eth0" => {"name", red_id}} = domains(context)
    assert red_id == red.id
  end

  test "mappings and authority are for owners and admins, inside the organization", context do
    user = user_fixture()
    organization_membership_fixture(user, context.organization, %{role: "member"})
    member = Accounts.scope_for_user(user, context.organization.id)

    assert {:error, :forbidden} =
             RoutingDomains.put_mapping(member, context.agent.id, "blue", nil)

    assert {:error, :forbidden} =
             RoutingDomains.set_source_authority(member, context.agent.id, false)

    other = organization_fixture()

    {:ok, foreign} =
      Inventory.create_source(%Accounts.Scope{organization_id: other.id}, %{
        kind: "manual",
        name: "x"
      })

    assert_raise Ecto.NoResultsError, fn ->
      RoutingDomains.put_mapping(context.scope, foreign.id, "blue", nil)
    end
  end

  # Reports one resource's interfaces with routing-domain claims; `:absent`
  # leaves the field out.
  defp report(context, source, second, claims, suffix \\ "") do
    interfaces =
      Enum.map(claims, fn
        {name, :absent} -> %{"name" => name}
        {name, claim} -> %{"name" => name, "routing_domain" => claim}
      end)

    {:ok, observation} =
      Inventory.create_observation(context.scope, source.id, %{
        idempotency_key: "domains-#{second}#{suffix}",
        observed_at: DateTime.add(~U[2026-08-01 12:00:00Z], second, :second),
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

    {:ok, _resource, _created?} = Inventory.reconcile_observation(context.scope, observation.id)
    observation
  end

  defp domains(context) do
    InterfaceRoutingDomain
    |> where([d], d.organization_id == ^context.scope.organization_id)
    |> join(:inner, [d], i in Inventory.Interface, on: i.id == d.interface_id)
    |> select([d, i], {i.name, {d.resolution, d.vrf_id}})
    |> Repo.all()
    |> Map.new()
  end

  defp active_keys(context) do
    RoutingDomainEvidence
    |> where([e], e.organization_id == ^context.scope.organization_id and is_nil(e.stale_at))
    |> select([e], e.source_local_key)
    |> Repo.all()
  end
end
