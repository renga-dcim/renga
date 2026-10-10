defmodule Renga.IPAM.NamespaceCorrelationTest do
  @moduledoc """
  Observed addresses correlate in their resolved namespace (RFD 4, Phase 6):
  the routing domain their interface's claim resolves to, or the global
  table without a claim. Utilization, prefix views, findings, and adoption
  all follow it, and an unmapped claim takes an address out of every
  namespace-dependent comparison.
  """
  use Renga.DataCase, async: true

  import Renga.AccountsFixtures
  import Renga.InventoryFixtures
  import Renga.TopologyFixtures

  alias Renga.Accounts
  alias Renga.Findings
  alias Renga.Inventory
  alias Renga.IPAM
  alias Renga.IPAM.AddressFinding

  setup do
    organization = organization_fixture()
    user = user_fixture()
    organization_membership_fixture(user, organization, %{role: "admin"})
    scope = Accounts.scope_for_user(user, organization.id)
    {:ok, agent} = Inventory.create_source(scope, %{kind: "host_agent", name: "agent"})
    blue = vrf_fixture(scope, "blue")
    %{scope: scope, agent: agent, blue: blue}
  end

  test "an address counts and appears in the namespace its interface is in", context do
    global = prefix_fixture(context.scope, "10.0.0.0/24")
    in_blue = prefix_fixture(context.scope, "10.0.0.0/24", %{vrf_id: context.blue.id})

    report(context, 1, [
      {"eth0", "10.0.0.5/24", %{"key" => "blue"}},
      {"eth1", "10.0.0.6/24", :absent},
      {"eth2", "10.0.0.7/24", %{"key" => "lab"}}
    ])

    hosts = fn prefix ->
      context.scope
      |> IPAM.prefix_view(prefix)
      |> Map.fetch!(:addresses)
      |> Enum.map(&IPAM.Cidr.format(%{&1.address.address | netmask: nil}))
    end

    assert hosts.(in_blue) == ["10.0.0.5"]
    # The unmapped address counts nowhere.
    assert hosts.(global) == ["10.0.0.6"]

    used = fn vrf_id ->
      %{ipv4: [row]} = IPAM.list_prefix_rows(context.scope, vrf_id)
      row.usage.used
    end

    assert used.(context.blue.id) == 1
    assert used.(nil) == 1
  end

  test "findings compare each address in its own namespace", context do
    prefix_fixture(context.scope, "10.0.0.0/24", %{vrf_id: context.blue.id, strict: true})
    prefix_fixture(context.scope, "10.0.0.0/24")

    report(context, 1, [
      {"eth0", "10.0.0.5/24", %{"key" => "blue"}},
      {"eth1", "10.0.0.5/24", :absent},
      {"eth2", "10.0.0.9/24", %{"key" => "BLUE"}},
      {"eth3", "10.0.0.9/24", %{"key" => "blue"}}
    ])

    # The same host in blue and global is two addresses, not a duplicate;
    # two interfaces in blue are. Blue's strict prefix flags its own
    # unmanaged addresses only.
    assert open_findings(context) == [
             {"duplicate_address", "eth2", "10.0.0.9 (blue) is also observed on eth3 on server"},
             {"duplicate_address", "eth3", "10.0.0.9 (blue) is also observed on eth2 on server"},
             {"unmanaged_in_strict_prefix", "eth0",
              "10.0.0.5 (blue) is observed in strict prefix 10.0.0.0/24 without a managed record"},
             {"unmanaged_in_strict_prefix", "eth2",
              "10.0.0.9 (blue) is observed in strict prefix 10.0.0.0/24 without a managed record"},
             {"unmanaged_in_strict_prefix", "eth3",
              "10.0.0.9 (blue) is observed in strict prefix 10.0.0.0/24 without a managed record"}
           ]

    blue_id = context.blue.id

    assert {[_, _, _, _, _], 5} =
             Findings.list_address_findings(context.scope, [cidr("10.0.0.0/24")], vrf_id: blue_id)

    assert {[], 0} =
             Findings.list_address_findings(context.scope, [cidr("10.0.0.0/24")], vrf_id: nil)
  end

  test "an unmapped claim takes an address out of findings and adoption", context do
    prefix_fixture(context.scope, "10.0.0.0/24", %{strict: true})
    report(context, 1, [{"eth0", "10.0.0.5/24", %{"key" => "lab"}}])
    [observed] = observed(context)

    assert open_findings(context) == []
    assert %{unmapped?: true, managed?: false} = IPAM.observed_address(context.scope, observed.id)
    assert {:error, :unmapped_routing_domain} = IPAM.adopt_address(context.scope, observed.id)

    # Mapped to blue, it is adopted there.
    {:ok, _} =
      IPAM.RoutingDomains.put_mapping(context.scope, context.agent.id, "lab", context.blue.id)

    assert {:ok, managed} = IPAM.adopt_address(context.scope, observed.id)
    assert managed.vrf_id == context.blue.id
    assert %{managed?: true, vrf_id: blue_id} = IPAM.observed_address(context.scope, observed.id)
    assert blue_id == context.blue.id
  end

  test "a VRF assignment is current while its interface reports it in that VRF", context do
    report(context, 1, [{"eth0", "10.0.0.5/24", %{"key" => "blue"}}])
    [observed] = observed(context)
    {:ok, _managed} = IPAM.adopt_address(context.scope, observed.id)
    assert open_findings(context) == []

    report(context, 2, [{"eth0", :none, %{"key" => "blue"}}])

    assert [
             {"stale_managed_assignment", "eth0",
              "Managed address 10.0.0.5 (blue) is not observed on eth0"}
           ] = open_findings(context)

    report(context, 3, [{"eth0", "10.0.0.5/24", %{"key" => "blue"}}])
    assert open_findings(context) == []
  end

  # Reports router-1's interfaces as `{name, address | :none, claim | :absent}`.
  defp report(context, second, interfaces) do
    interfaces =
      Enum.map(interfaces, fn {name, address, claim} ->
        %{"name" => name, "addresses" => if(address == :none, do: [], else: [address])}
        |> then(&if(claim == :absent, do: &1, else: Map.put(&1, "routing_domain", claim)))
      end)

    {:ok, observation} =
      Inventory.create_observation(context.scope, context.agent.id, %{
        idempotency_key: "namespaces-#{second}",
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
  end

  defp observed(context) do
    Inventory.Address
    |> where([a], a.organization_id == ^context.scope.organization_id)
    |> Repo.all()
  end

  defp open_findings(context) do
    AddressFinding
    |> where([f], f.organization_id == ^context.scope.organization_id and f.status == "open")
    |> join(:inner, [f], i in assoc(f, :interface))
    |> select([f, i], {f.kind, i.name, f.message})
    |> Repo.all()
    |> Enum.sort()
  end

  defp cidr(text) do
    {:ok, cidr} = Renga.Types.Inet.cast(text)
    cidr
  end
end
