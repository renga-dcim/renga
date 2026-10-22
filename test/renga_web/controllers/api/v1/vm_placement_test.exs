defmodule RengaWeb.Api.V1.VmPlacementTest do
  @moduledoc """
  RFD 11 phase 3: defined-on versus active VM placement from libvirt reports.
  """

  use RengaWeb.ConnCase, async: true

  import Renga.AccountsFixtures
  import Ecto.Query
  import Renga.InventoryFixtures

  alias Renga.Accounts
  alias Renga.Inventory
  alias Renga.Inventory.CollectorFinding
  alias Renga.Inventory.VmPlacements
  alias Renga.Repo

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

  test "a withdrawal ends the active run", %{scope: scope, token: token} do
    vm_id = report!(token, "hv-a", "running", at: 0)
    post!(token, hypervisor_report("hv-a", [], at: 5, complete: true))
    # Reported again by identity alone: defined there, but not shown active.
    post!(token, hypervisor_report("hv-a", [identity_only()], at: 6))

    assert %{status: :unknown, defined_on: [_defined]} =
             VmPlacements.placement(scope, vm_id, at(7))

    report!(token, "hv-a", "running", at: 8)
    assert %{status: :placed, hypervisor: claim} = VmPlacements.placement(scope, vm_id, at(9))
    assert DateTime.compare(claim.active_since, at(8)) == :eq
  end

  test "an active report replayed behind a withdrawal starts no run", %{
    scope: scope,
    token: token
  } do
    post!(token, hypervisor_report("hv-a", [], at: 5, complete: true))
    vm_id = report!(token, "hv-a", "running", at: 0)
    post!(token, hypervisor_report("hv-a", [identity_only()], at: 6))

    assert %{status: :unknown} = VmPlacements.placement(scope, vm_id, at(7))

    report!(token, "hv-a", "running", at: 8)
    assert %{status: :placed, hypervisor: claim} = VmPlacements.placement(scope, vm_id, at(9))
    assert DateTime.compare(claim.active_since, at(8)) == :eq
  end

  test "a late replay never revives an active claim", %{scope: scope, token: token} do
    vm_id = report!(token, "hv-a", "shutoff", at: 5)
    report!(token, "hv-a", "running", at: 0)

    assert %{status: :unknown, defined_on: [%{domain: %{"state" => "shutoff"}}]} =
             VmPlacements.placement(scope, vm_id, at(6))
  end

  test "a local hypervisor links to the host its agent reports", %{scope: scope, token: token} do
    host_id = host!(token)

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

    # Neither a dummy driver nor an external transport is the host itself.
    for {collector, uri} <- [
          {"test", "test:///default"},
          {"ext", "qemu+ext:///system?command=/opt/tunnel"}
        ] do
      report!(token, collector, "shutoff", at: 0, uri: uri)
    end

    hosts =
      VmPlacements.placement(scope, vm_id, at(1)).defined_on
      |> Map.new(&{&1.target.key, &1.host_resource_id})

    assert hosts["test:///default"] == nil
    assert hosts["qemu+ext:///system?command=/opt/tunnel"] == nil
  end

  test "another stream on an active hypervisor does not settle a conflict", %{
    scope: scope,
    token: token
  } do
    host_id = host!(token)
    vm_id = report!(token, "local-1", "running", at: 0, uri: "qemu:///system")
    report!(token, "hv-b", "running", at: 2)
    report!(token, "local-1", "running", at: 5, uri: "qemu:///system")
    assert %{status: :ambiguous} = VmPlacements.placement(scope, vm_id, at(6))

    # A second collector on the same installation reads the same hypervisor.
    report!(token, "local-2", "running", at: 6, uri: "qemu:///system")
    placement = VmPlacements.placement(scope, vm_id, at(7))
    assert placement.status == :ambiguous

    assert placement.active |> Enum.map(& &1.host_resource_id) |> Enum.count(&(&1 == host_id)) ==
             2
  end

  describe "possible same machine" do
    # Findings are judged by the server's clock, so these reports are recent.
    setup do
      base = DateTime.add(Renga.Time.utc_now_ms(), -10 * 60)
      %{recent: &DateTime.add(base, &1 * 60)}
    end

    test "a guest without a UUID whose MACs cover one domain opens a finding", %{
      scope: scope,
      token: token,
      recent: recent
    } do
      %{"reconciliation" => %{"resources" => [%{"resource_id" => vm_id}]}} =
        post!(
          token,
          hypervisor_report("hv-a", [vm("running", macs: ["52:54:00:00:00:01"])], at: recent.(0))
        )

      guest_id = guest!(token, ["52-54-00-00-00-01", "02:42:ac:11:00:01"], at: recent.(1))
      refute guest_id == vm_id

      assert [%CollectorFinding{status: "open", details: details}] = findings(guest_id)
      assert details["vm_resource_id"] == vm_id
      assert details["mac_addresses"] == ["52:54:00:00:00:01"]
      assert details["hypervisors"] == ["qemu+ssh://hv-a/system"]

      assert {[%{domain: "collector", kind: "possible_same_machine"}], 1} =
               Renga.Findings.list_findings(scope, resource_id: guest_id)

      # Credentials another client put in a URI stay out of what members see.
      post!(
        token,
        hypervisor_report("hv-c", [vm("shutoff", macs: ["52:54:00:00:00:01"])],
          at: recent.(1),
          uri: "qemu+ssh://root:hunter2@hv-c/system?keyfile=/root/.ssh/id"
        )
      )

      assert [%CollectorFinding{details: %{"hypervisors" => hypervisors}}] = findings(guest_id)
      assert hypervisors == ["qemu+ssh://hv-a/system", "qemu+ssh://hv-c/system"]

      # The domain's NIC changes, so its MACs no longer single the guest out.
      for {hypervisor, uri} <- [
            {"hv-a", "qemu+ssh://hv-a/system"},
            {"hv-c", "qemu+ssh://root:hunter2@hv-c/system?keyfile=/root/.ssh/id"}
          ] do
        post!(
          token,
          hypervisor_report(hypervisor, [vm("running", macs: ["52:54:00:00:00:09"])],
            at: recent.(2),
            uri: uri
          )
        )
      end

      assert [%CollectorFinding{status: "resolved"}] = findings(guest_id)
    end

    test "the guest may report first", %{token: token, recent: recent} do
      guest_id = guest!(token, ["52:54:00:00:00:01"], at: recent.(0))
      assert findings(guest_id) == []

      post!(
        token,
        hypervisor_report("hv-a", [vm("shutoff", macs: ["52:54:00:00:00:01"])], at: recent.(1))
      )

      assert [%CollectorFinding{status: "open"}] = findings(guest_id)
    end

    test "cloned MACs on two domains, or a guest UUID, open nothing", %{
      token: token,
      recent: recent
    } do
      post!(
        token,
        hypervisor_report("hv-a", [vm("running", macs: ["52:54:00:00:00:01"])], at: recent.(0))
      )

      clone = %{
        vm("running", macs: ["52:54:00:00:00:01"])
        | "identifiers" => %{"dmi_uuid" => "0d8f6f2c-3a4b-4c5d-8e9f-0a1b2c3d4e5f"}
      }

      post!(token, hypervisor_report("hv-b", [clone], at: recent.(0)))
      guest_id = guest!(token, ["52:54:00:00:00:01"], at: recent.(1))
      assert findings(guest_id) == []

      with_uuid =
        guest!(token, ["52:54:00:00:00:02"],
          at: recent.(1),
          dmi_uuid: "1e9a7b3d-4c5d-4e6f-9a0b-1c2d3e4f5a6b"
        )

      post!(
        token,
        hypervisor_report(
          "hv-c",
          [
            %{
              vm("running", macs: ["52:54:00:00:00:02"])
              | "identifiers" => %{"dmi_uuid" => "2f0b8c4e-5d6e-4f70-8b1c-2d3e4f5a6b7c"}
            }
          ],
          at: recent.(2)
        )
      )

      assert findings(with_uuid) == []
    end

    test "a finding resolves once its domain ages out with no further report", %{
      token: token,
      recent: recent
    } do
      post!(
        token,
        hypervisor_report("hv-a", [vm("running", macs: ["52:54:00:00:00:01"])], at: recent.(0))
      )

      guest_id = guest!(token, ["52:54:00:00:00:01"], at: recent.(1))
      assert [%CollectorFinding{status: "open"} = opened] = findings(guest_id)

      # Still fresh: the sweep leaves the finding as last observed.
      Renga.Inventory.SameMachineSweeper.sweep()
      assert [%CollectorFinding{status: "open"} = swept] = findings(guest_id)
      assert swept.last_observed_at == opened.last_observed_at

      # The hypervisor's last report is past the freshness window by now.
      Renga.Inventory.SameMachineSweeper.sweep(recent.(16))
      assert [%CollectorFinding{status: "resolved"}] = findings(guest_id)
    end

    test "a hypervisor host's macvtap carrying its guest's MAC is not a match", %{
      token: token,
      recent: recent
    } do
      post!(
        token,
        hypervisor_report("hv-a", [vm("running", macs: ["52:54:00:00:00:01"])], at: recent.(0))
      )

      host_id = guest!(token, ["52:54:00:00:00:01"], at: recent.(1), kind: "virtual")
      assert findings(host_id) == []
    end

    test "an unset firmware UUID does not stand in for a guest's own", %{
      token: token,
      recent: recent
    } do
      post!(
        token,
        hypervisor_report("hv-a", [vm("running", macs: ["52:54:00:00:00:01"])], at: recent.(0))
      )

      guest_id =
        guest!(token, ["52:54:00:00:00:01"],
          at: recent.(1),
          dmi_uuid: "FFFFFFFF-FFFF-FFFF-FFFF-FFFFFFFFFFFF"
        )

      assert [%CollectorFinding{status: "open"}] = findings(guest_id)
    end

    test "any hypervisor report can change what a guest matches", %{
      token: token,
      recent: recent
    } do
      post!(
        token,
        hypervisor_report("hv-a", [vm("running", macs: ["52:54:00:00:00:01"])], at: recent.(0))
      )

      clone = %{
        vm("running", macs: ["52:54:00:00:00:01"])
        | "identifiers" => %{"dmi_uuid" => "0d8f6f2c-3a4b-4c5d-8e9f-0a1b2c3d4e5f"}
      }

      post!(token, hypervisor_report("hv-b", [clone], at: recent.(0)))
      guest_id = guest!(token, ["52:54:00:00:00:01"], at: recent.(1))
      assert findings(guest_id) == []

      # The clone is withdrawn, so the remaining domain is unique.
      post!(token, hypervisor_report("hv-b", [], at: recent.(2), complete: true))
      assert [%CollectorFinding{status: "open"}] = findings(guest_id)

      # The remaining domain's hypervisor becomes unreachable: no fresh claim.
      post!(token, hypervisor_report("hv-a", [], at: recent.(3), status: "unreachable"))
      assert [%CollectorFinding{status: "resolved"}] = findings(guest_id)
    end

    test "dismissing a finding covers its pairing and no other", %{
      scope: scope,
      token: token,
      recent: recent
    } do
      other = %{
        vm("running", macs: ["52:54:00:00:00:01"])
        | "identifiers" => %{"dmi_uuid" => "0d8f6f2c-3a4b-4c5d-8e9f-0a1b2c3d4e5f"}
      }

      post!(
        token,
        hypervisor_report("hv-a", [vm("running", macs: ["52:54:00:00:00:01"])], at: recent.(0))
      )

      guest = [installation_id: Ecto.UUID.generate(), machine_id: "guest-dismissed"]
      guest_id = guest!(token, ["52:54:00:00:00:01"], [at: recent.(1)] ++ guest)

      {[finding], 1} = Renga.Findings.list_findings(scope, resource_id: guest_id)
      vm_a = finding.details["vm_resource_id"]

      {:ok, _finding} =
        Renga.Findings.accept_exception(scope, finding, %{"exception_reason" => "Lab twin"})

      # The same evidence again neither reopens it nor files another.
      guest!(token, ["52:54:00:00:00:01"], [at: recent.(2)] ++ guest)
      assert [%CollectorFinding{status: "open"}] = findings(guest_id)
      assert {[], 0} = Renga.Findings.list_findings(scope, resource_id: guest_id)

      # The guest's MAC now singles out a different VM: a new pairing.
      post!(
        token,
        hypervisor_report("hv-a", [vm("running", macs: ["52:54:00:00:00:09"])], at: recent.(3))
      )

      post!(token, hypervisor_report("hv-b", [other], at: recent.(3)))

      assert {[%{details: %{"vm_resource_id" => vm_b}}], 1} =
               Renga.Findings.list_findings(scope, resource_id: guest_id)

      refute vm_b == vm_a

      # Back to the first VM: its dismissal still holds.
      post!(token, hypervisor_report("hv-b", [], at: recent.(4), complete: true))

      post!(
        token,
        hypervisor_report("hv-a", [vm("running", macs: ["52:54:00:00:00:01"])], at: recent.(4))
      )

      assert {[], 0} = Renga.Findings.list_findings(scope, resource_id: guest_id)

      assert {[%{details: %{"vm_resource_id" => ^vm_a}}], 1} =
               Renga.Findings.list_findings(scope, resource_id: guest_id, state: "excepted")
    end

    test "a domain with no device list does not stop evaluation", %{
      token: token,
      recent: recent
    } do
      listless = %{
        "kind" => "vm",
        "identifiers" => %{"dmi_uuid" => "0d8f6f2c-3a4b-4c5d-8e9f-0a1b2c3d4e5f"},
        "domain" => %{"name" => "db-1", "state" => "running", "interfaces" => nil}
      }

      post!(token, hypervisor_report("hv-b", [listless], at: recent.(0)))

      post!(
        token,
        hypervisor_report("hv-a", [vm("running", macs: ["52:54:00:00:00:01"])], at: recent.(0))
      )

      guest_id = guest!(token, ["52:54:00:00:00:01"], at: recent.(1))
      assert [%CollectorFinding{status: "open"}] = findings(guest_id)

      post!(
        token,
        hypervisor_report("hv-a", [vm("running", macs: ["52:54:00:00:00:09"])], at: recent.(2))
      )

      assert [%CollectorFinding{status: "resolved"}] = findings(guest_id)
    end

    test "withdrawn evidence on either side is not evidence", %{token: token, recent: recent} do
      post!(
        token,
        hypervisor_report("hv-a", [vm("running", macs: ["52:54:00:00:00:01"])], at: recent.(0))
      )

      post!(token, hypervisor_report("hv-a", [], at: recent.(1), complete: true))
      # Back by identity alone, so its domain view predates the withdrawal.
      post!(token, hypervisor_report("hv-a", [identity_only()], at: recent.(2)))
      assert findings(guest!(token, ["52:54:00:00:00:01"], at: recent.(3))) == []

      # A guest that stops reporting the matching NIC no longer carries it.
      post!(
        token,
        hypervisor_report("hv-b", [vm("running", macs: ["52:54:00:00:00:02"])], at: recent.(4))
      )

      guest = [installation_id: Ecto.UUID.generate(), machine_id: "guest-nic-removed"]
      guest_id = guest!(token, ["52:54:00:00:00:02"], [at: recent.(5)] ++ guest)
      assert [%CollectorFinding{status: "open"}] = findings(guest_id)

      assert guest!(token, [], [at: recent.(6)] ++ guest) == guest_id
      assert [%CollectorFinding{status: "resolved"}] = findings(guest_id)
    end

    test "stale domains are not evidence, even to a guest report as old", %{
      token: token,
      recent: recent
    } do
      post!(
        token,
        hypervisor_report("hv-a", [vm("running", macs: ["52:54:00:00:00:01"])], at: recent.(-20))
      )

      # A minute after the domain, but replayed now, when the domain is stale.
      guest_id = guest!(token, ["52:54:00:00:00:01"], at: recent.(-19))
      assert findings(guest_id) == []
    end
  end

  defp guest!(token, macs, opts) do
    identifiers =
      %{"machine_id" => opts[:machine_id] || "guest-#{System.unique_integer([:positive])}"}
      |> then(&if(opts[:dmi_uuid], do: Map.put(&1, "dmi_uuid", opts[:dmi_uuid]), else: &1))

    interfaces =
      macs
      |> Enum.with_index()
      |> Enum.map(fn {mac, index} ->
        %{"name" => "eth#{index}", "kind" => opts[:kind] || "ethernet", "mac_address" => mac}
      end)

    %{"reconciliation" => %{"matched_resource_id" => guest_id}} =
      post!(
        token,
        %{
          :installation_id => opts[:installation_id] || Ecto.UUID.generate(),
          "observation_id" => "guest-#{System.unique_integer([:positive])}",
          "observed_at" => DateTime.to_iso8601(observed_at(opts)),
          "resources" => [
            %{"kind" => "server", "identifiers" => identifiers, "interfaces" => interfaces}
          ]
        }
      )

    guest_id
  end

  defp findings(resource_id) do
    Repo.all(
      from finding in CollectorFinding,
        where: finding.resource_id == ^resource_id and finding.kind == "possible_same_machine"
    )
  end

  defp report!(token, hypervisor, state, opts) do
    %{"reconciliation" => %{"resources" => [%{"resource_id" => vm_id}]}} =
      post!(token, hypervisor_report(hypervisor, [vm(state)], opts))

    vm_id
  end

  # The installation's own host, as its agent reports it.
  defp host!(token) do
    post!(token, %{
      "observation_id" => "host-1",
      "observed_at" => DateTime.to_iso8601(@t0),
      "resources" => [%{"kind" => "server", "identifiers" => %{"machine_id" => "hv-a-machine"}}]
    })["reconciliation"]["matched_resource_id"]
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
      "observed_at" => DateTime.to_iso8601(observed_at(opts)),
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

  defp vm(state, opts \\ []) do
    interfaces =
      Enum.map(Keyword.get(opts, :macs, []), &%{"mac_address" => &1, "type" => "bridge"})

    %{
      "kind" => "vm",
      "identifiers" => %{"dmi_uuid" => @vm},
      "domain" => %{
        "name" => "web-1",
        "state" => state,
        "persistent" => true,
        "interfaces" => interfaces
      }
    }
  end

  defp identity_only, do: Map.delete(vm("running"), "domain")

  defp keys(hypervisors), do: Enum.map(hypervisors, &"qemu+ssh://#{&1}/system")

  defp observed_at(opts) do
    case Keyword.fetch!(opts, :at) do
      %DateTime{} = at -> at
      minutes -> at(minutes)
    end
  end

  defp at(minutes), do: DateTime.add(@t0, minutes * 60)
end
