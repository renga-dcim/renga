defmodule RengaWeb.Api.V1.VmPlacementTest do
  @moduledoc """
  RFD 11 phase 3: defined-on versus active VM placement from libvirt reports.
  """

  use RengaWeb.ConnCase, async: true

  import Renga.AccountsFixtures
  import Renga.InventoryFixtures

  alias Renga.Accounts
  alias Renga.Inventory
  alias Renga.Inventory.VmPlacements

  @installation_id "67e55044-10b1-426f-9247-bb680e5fe0c8"
  @other_installation_id "8ea9ae04-bf9b-4c34-8192-4f617eade95e"
  @vm "6a4f3c2e-1b2d-4e5f-8a9b-0c1d2e3f4a5b"
  @t0 ~U[2026-08-13 07:30:00.000Z]

  setup do
    user = user_fixture()
    organization = organization_fixture()
    organization_membership_fixture(user, organization, %{role: "admin"})
    scope = Accounts.scope_for_user(user, organization.id)
    {:ok, {_key, token}} = Inventory.create_intake_api_key(scope, %{name: "Fleet"})

    %{scope: scope, token: token}
  end

  test "an inactive definition never places the VM", %{scope: scope, token: token} do
    vm_id = report!(token, "hv-a", "running", at: 0)
    report!(token, "hv-b", "shutoff", at: 0)

    placement = VmPlacements.placement(scope, vm_id, at(1))
    assert placement.status == :placed
    assert placement.hypervisor.target.key == "qemu+ssh://hv-a/system"
    assert placement.defined_on |> Enum.map(& &1.target.key) |> Enum.sort() == keys(~w(hv-a hv-b))
  end

  test "a migrated VM moves once the destination reports it", %{scope: scope, token: token} do
    vm_id = report!(token, "hv-a", "running", at: 0)
    report!(token, "hv-b", "running", at: 2)

    # The source has not polled since; its claim predates the destination's.
    assert %{status: :placed, hypervisor: %{target: %{key: "qemu+ssh://hv-b/system"}}} =
             VmPlacements.placement(scope, vm_id, at(3))

    # The persistent definition left on the source is not a claim.
    report!(token, "hv-a", "shutoff", at: 5)

    assert %{status: :placed, hypervisor: %{target: %{key: "qemu+ssh://hv-b/system"}}} =
             placement = VmPlacements.placement(scope, vm_id, at(6))

    assert length(placement.defined_on) == 2
  end

  test "competing fresh active claims leave placement ambiguous", %{
    scope: scope,
    token: token
  } do
    vm_id = report!(token, "hv-a", "running", at: 0)
    report!(token, "hv-b", "paused", at: 2)
    report!(token, "hv-a", "running", at: 5)

    placement = VmPlacements.placement(scope, vm_id, at(6))
    assert placement.status == :ambiguous
    assert placement.hypervisor == nil
    assert length(placement.active) == 2
  end

  test "stale or unreachable evidence leaves placement unknown", %{scope: scope, token: token} do
    vm_id = report!(token, "hv-a", "running", at: 0)

    assert %{status: :placed} = VmPlacements.placement(scope, vm_id, at(15))
    assert %{status: :unknown} = VmPlacements.placement(scope, vm_id, at(16))

    post!(token, hypervisor_report("hv-a", [], at: 5, status: "unreachable"))

    assert %{status: :unknown, defined_on: [_defined]} =
             VmPlacements.placement(scope, vm_id, at(6))
  end

  test "a complete report without the domain withdraws its claim", %{scope: scope, token: token} do
    vm_id = report!(token, "hv-a", "running", at: 0)
    post!(token, hypervisor_report("hv-a", [], at: 5, complete: true))

    assert %{status: :unknown, defined_on: []} = VmPlacements.placement(scope, vm_id, at(6))
  end

  test "a late replay never revives an active claim", %{scope: scope, token: token} do
    vm_id = report!(token, "hv-a", "shutoff", at: 5)
    report!(token, "hv-a", "running", at: 0)

    assert %{status: :unknown, defined_on: [%{domain: %{"state" => "shutoff"}}]} =
             VmPlacements.placement(scope, vm_id, at(6))
  end

  test "a local hypervisor links to the host its agent reports", %{scope: scope, token: token} do
    host =
      post!(token, %{
        "observation_id" => "host-1",
        "observed_at" => DateTime.to_iso8601(@t0),
        "resources" => [
          %{"kind" => "server", "identifiers" => %{"machine_id" => "hv-a-machine"}}
        ]
      })

    host_id = host["reconciliation"]["matched_resource_id"]

    %{"reconciliation" => %{"resources" => [%{"resource_id" => vm_id}]}} =
      post!(
        token,
        hypervisor_report("hv-a", [vm("running")], at: 0, uri: "qemu:///system")
      )

    assert %{status: :placed, hypervisor: %{host_resource_id: ^host_id}} =
             VmPlacements.placement(scope, vm_id, at(1))

    # A remote URI names some other machine.
    post!(
      token,
      hypervisor_report("hv-b", [vm("shutoff")], at: 0, installation_id: @other_installation_id)
    )

    hosts =
      VmPlacements.placement(scope, vm_id, at(1)).defined_on |> Enum.map(& &1.host_resource_id)

    assert Enum.sort(hosts, :desc) == [host_id, nil]
  end

  defp report!(token, hypervisor, state, opts) do
    %{"reconciliation" => %{"resources" => [%{"resource_id" => vm_id}]}} =
      post!(token, hypervisor_report(hypervisor, [vm(state)], opts))

    vm_id
  end

  defp post!(token, payload) do
    installation_id = Map.get(payload, :installation_id, @installation_id)

    build_conn()
    |> put_req_header("authorization", "Bearer #{token}")
    |> put_req_header("x-renga-installation-id", installation_id)
    |> post(~p"/api/v1/observations", Map.delete(payload, :installation_id))
    |> valid_api_response(202)
  end

  defp hypervisor_report(hypervisor, resources, opts) do
    %{
      :installation_id => Keyword.get(opts, :installation_id, @installation_id),
      "observation_id" => "libvirt-#{System.unique_integer([:positive])}",
      "observed_at" => DateTime.to_iso8601(at(Keyword.fetch!(opts, :at))),
      "scope" => "hypervisor",
      "collector" => %{"id" => hypervisor, "kind" => "vm_provider"},
      "hypervisor" => %{
        "id" => Keyword.get(opts, :uri, "qemu+ssh://#{hypervisor}/system"),
        "status" => Keyword.get(opts, :status, "reachable")
      },
      "complete" => Keyword.get(opts, :complete, false),
      "resources" => resources
    }
  end

  defp vm(state) do
    %{
      "kind" => "vm",
      "identifiers" => %{"dmi_uuid" => @vm},
      "domain" => %{"name" => "web-1", "state" => state, "persistent" => true}
    }
  end

  defp keys(hypervisors), do: Enum.map(hypervisors, &"qemu+ssh://#{&1}/system")

  defp at(minutes), do: DateTime.add(@t0, minutes * 60)
end
