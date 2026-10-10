defmodule Renga.IPAM.AddressFindingsTest do
  @moduledoc """
  Address findings (RFD 4, Phase 5): reconciliation opens a finding for each
  namespace-independent condition, with its involved records and source
  evidence, and resolves it as observed state converges, without deleting
  observations, evidence, change events, or the resolved finding itself.
  """
  use Renga.DataCase, async: true

  import Renga.AccountsFixtures
  import Renga.InventoryFixtures
  import Renga.TopologyFixtures

  alias Renga.Accounts
  alias Renga.Inventory
  alias Renga.IPAM
  alias Renga.IPAM.AddressFinding
  alias Renga.IPAM.AddressFindings

  setup do
    organization = organization_fixture()
    user = user_fixture()
    organization_membership_fixture(user, organization, %{role: "admin"})
    scope = Accounts.scope_for_user(user, organization.id)
    {web, web_ports} = device_fixture(scope, "server", "web-01", ~w(eth0 eth1))
    {_db, db_ports} = device_fixture(scope, "server", "db-01", ~w(eth0))

    %{
      scope: scope,
      web: web,
      web_eth0: web_ports["eth0"],
      web_eth1: web_ports["eth1"],
      db_eth0: db_ports["eth0"]
    }
  end

  test "an organization that has not modeled addresses sees no findings", context do
    address_fixture(context.scope, context.web_eth0, "192.0.2.5/24")
    address_fixture(context.scope, context.web_eth1, "2001:db8::5/64")
    reconcile(context)
    assert open(context) == []

    # Modeling IPv4 flags IPv4 hosts outside every prefix, never IPv6 ones,
    # and never loopback or link-local addresses, unique by nobody's design.
    address_fixture(context.scope, context.web_eth0, "127.0.0.1/8")
    address_fixture(context.scope, context.web_eth1, "fe80::1/64")
    address_fixture(context.scope, context.db_eth0, "fe80::1/64")
    prefix_fixture(context.scope, "10.0.0.0/8")

    assert [
             {"outside_prefix", eth0_id, "192.0.2.5",
              "192.0.2.5 is observed outside every prefix"}
           ] =
             open(context)

    assert eth0_id == context.web_eth0.id

    # A prefix that covers the host resolves it.
    prefix_fixture(context.scope, "192.0.2.0/24")
    assert open(context) == []
    assert [%{status: "resolved", resolved_at: %DateTime{}}] = all(context, "outside_prefix")
  end

  test "a strict prefix expects a managed record for each observed address", context do
    strict = prefix_fixture(context.scope, "192.0.2.0/24", %{strict: true})
    # A non-strict prefix inside cannot opt out: the policy is a boolean.
    prefix_fixture(context.scope, "192.0.2.0/26")
    observed = address_fixture(context.scope, context.web_eth0, "192.0.2.5/26")
    address_fixture(context.scope, context.db_eth0, "198.51.100.5/24")
    reconcile(context)

    # Outside the strict prefix, an unmanaged address is only outside it.
    assert [
             {"outside_prefix", _, "198.51.100.5", _},
             {"unmanaged_in_strict_prefix", _, "192.0.2.5", message}
           ] = open(context)

    assert message ==
             "192.0.2.5 is observed in strict prefix 192.0.2.0/24 without a managed record"

    assert [%{details: %{"prefix_id" => prefix_id, "observed_address_id" => observed_id}}] =
             all(context, "unmanaged_in_strict_prefix")

    assert {prefix_id, observed_id} == {strict.id, observed.id}

    # Adopting resolves it; releasing brings it back as a new occurrence of
    # the same identity, so its workflow would follow.
    {:ok, managed} = IPAM.adopt_address(context.scope, observed.id)
    assert [{"outside_prefix", _, _, _}] = open(context)
    {:ok, _} = IPAM.release_address(context.scope, managed.id)
    assert [_outside, {"unmanaged_in_strict_prefix", _, "192.0.2.5", _}] = open(context)

    assert ["open", "resolved"] =
             context |> all("unmanaged_in_strict_prefix") |> Enum.map(& &1.status) |> Enum.sort()
  end

  test "an observed mask that disagrees with its subnet is a finding", context do
    prefix_fixture(context.scope, "192.0.2.0/24")
    prefix_fixture(context.scope, "10.0.0.0/8", %{status: "container"})
    address_fixture(context.scope, context.web_eth0, "192.0.2.7/26")
    # Host-length reports usually mean the mask was unknown.
    address_fixture(context.scope, context.web_eth1, "192.0.2.8/32")
    # A container is not a subnet.
    address_fixture(context.scope, context.db_eth0, "10.1.1.1/24")
    reconcile(context)

    assert [
             {"prefix_length_mismatch", _, "192.0.2.7",
              "192.0.2.7 is observed as /26 in prefix 192.0.2.0/24"}
           ] =
             open(context)

    assert [%{details: %{"observed_length" => 26, "prefix_length" => 24}}] =
             all(context, "prefix_length_mismatch")

    # Containers model coverage, but do not hide the enclosing subnet's mask.
    prefix_fixture(context.scope, "192.0.2.0/27", %{status: "container"})
    assert [{"prefix_length_mismatch", _, "192.0.2.7", _}] = open(context)

    assert [%{details: %{"prefix_length" => 24}, status: "open"}] =
             all(context, "prefix_length_mismatch")
  end

  test "a host on several interfaces is a duplicate unless its role is shared", context do
    prefix_fixture(context.scope, "192.0.2.0/24")
    web = address_fixture(context.scope, context.web_eth0, "192.0.2.9/24")
    address_fixture(context.scope, context.db_eth0, "192.0.2.9/24")
    reconcile(context)

    assert [
             {"duplicate_address", first, "192.0.2.9",
              "192.0.2.9 is also observed on eth0 on " <> _},
             {"duplicate_address", second, "192.0.2.9", _}
           ] = open(context)

    assert Enum.sort([first, second]) == Enum.sort([context.web_eth0.id, context.db_eth0.id])

    finding =
      Enum.find(all(context, "duplicate_address"), &(&1.interface_id == context.web_eth0.id))

    assert [%{"interface_id" => other, "resource" => "db-01"}] = finding.details["others"]
    assert other == context.db_eth0.id

    # A VIP is meant to be on both.
    {:ok, managed} = IPAM.adopt_address(context.scope, web.id)
    {:ok, _vip} = IPAM.update_ip_address(context.scope, managed, %{role: "vip"})
    assert open(context) == []
  end

  test "a managed assignment a collector stops reporting goes stale, then converges", context do
    {:ok, source} = Inventory.create_source(context.scope, %{kind: "host_agent", name: "agent"})
    [observed] = report_addresses(context.scope, source, ["192.0.2.5/24"])
    {:ok, managed} = IPAM.adopt_address(context.scope, observed.id)
    events_before = Repo.aggregate(Inventory.ChangeEvent, :count)

    report_addresses(context.scope, source, [])

    assert [{"stale_managed_assignment", interface_id, key, message}] = open(context)
    assert {interface_id, key} == {observed.interface_id, managed.id}
    assert message == "Managed address 192.0.2.5 is not observed on eth0"

    # Reported again, the assignment is current and the finding resolves;
    # the evidence and history of both reports remain.
    report_addresses(context.scope, source, ["192.0.2.5/24"])
    assert open(context) == []
    assert [%{status: "resolved"}] = all(context, "stale_managed_assignment")
    assert Repo.aggregate(Inventory.AddressEvidence, :count) == 2
    assert Repo.aggregate(Inventory.ChangeEvent, :count) > events_before

    # A documented assignment on a device no collector reports addresses for
    # is not "not observed".
    {:ok, reserved} = IPAM.create_ip_address(context.scope, %{address: "198.51.100.7/24"})

    {:ok, allocated} =
      IPAM.update_ip_address(context.scope, reserved, %{allocation_state: "allocated"})

    {:ok, _} = IPAM.assign_address(context.scope, allocated.id, context.db_eth0.id)
    assert open(context) == []
  end

  test "findings carry each source's reports as evidence", context do
    {:ok, source} = Inventory.create_source(context.scope, %{kind: "host_agent", name: "agent"})
    prefix_fixture(context.scope, "192.0.2.0/24", %{strict: true})
    report_addresses(context.scope, source, ["192.0.2.5/24", "192.0.2.5/32"])

    assert [%{details: %{"evidence" => evidence, "address" => "192.0.2.5/24"}}] =
             all(context, "unmanaged_in_strict_prefix")

    assert evidence |> Enum.map(& &1["address"]) |> Enum.sort() == ["192.0.2.5", "192.0.2.5/24"]
    assert Enum.all?(evidence, &(&1["source_id"] == source.id and &1["source"] == "agent"))
  end

  test "a reconcile that finds nothing new writes nothing", context do
    prefix_fixture(context.scope, "10.0.0.0/8")
    address_fixture(context.scope, context.web_eth0, "192.0.2.5/24")
    reconcile(context)
    [before] = all(context, "outside_prefix")

    reconcile(context)
    assert [^before] = all(context, "outside_prefix")
  end

  test "findings stay inside their organization", context do
    other = organization_fixture()
    prefix_fixture(context.scope, "10.0.0.0/8")
    address_fixture(context.scope, context.web_eth0, "192.0.2.5/24")
    reconcile(context)

    {:ok, :ok} = AddressFindings.reconcile(other.id)
    assert [_one] = open(context)

    assert Repo.all(from f in AddressFinding, where: f.organization_id == ^other.id) ==
             []
  end

  defp reconcile(context),
    do: {:ok, :ok} = AddressFindings.reconcile(context.scope.organization_id)

  defp open(context) do
    AddressFinding
    |> where([f], f.organization_id == ^context.scope.organization_id and f.status == "open")
    |> order_by([f], asc: f.kind, asc: f.resolution_key, asc: f.inserted_at)
    |> Repo.all()
    |> Enum.map(&{&1.kind, &1.interface_id, &1.resolution_key, &1.message})
  end

  defp all(context, kind) do
    AddressFinding
    |> where([f], f.organization_id == ^context.scope.organization_id and f.kind == ^kind)
    |> order_by([f], asc: f.inserted_at)
    |> Repo.all()
  end
end
