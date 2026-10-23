defmodule RengaWeb.Api.V1.GuestWithoutVmTest do
  @moduledoc """
  RFD 11 phase 4: the opt-in guest-without-VM collector finding.
  """

  use RengaWeb.ConnCase, async: true

  import Ecto.Query
  import Phoenix.LiveViewTest
  import Renga.AccountsFixtures
  import Renga.InventoryFixtures

  alias Renga.Accounts
  alias Renga.Inventory
  alias Renga.Inventory.AgentLease
  alias Renga.Inventory.CollectorFinding
  alias Renga.Inventory.CollectorFindings
  alias Renga.Inventory.CollectorFindingsWorker
  alias Renga.Repo

  @guest_installation "0d7c8f4e-2a1b-4c3d-9e8f-7a6b5c4d3e2f"
  @hypervisor_installation "67e55044-10b1-426f-9247-bb680e5fe0c8"
  @uuid "6a4f3c2e-1b2d-4e5f-8a9b-0c1d2e3f4a5b"

  setup do
    user = user_fixture()
    organization = organization_fixture()
    organization_membership_fixture(user, organization, %{role: "owner"})
    scope = Accounts.scope_for_user(user, organization.id)
    {:ok, {_key, token}} = Inventory.create_intake_api_key(scope, %{name: "Fleet"})

    %{scope: scope, token: token, user: user}
  end

  test "is off until the organization opts in", %{scope: scope, token: token} do
    guest_id = guest!(token)
    refresh!(scope)
    assert open_findings(guest_id) == []

    assert {:ok, true} = CollectorFindings.set_guest_without_vm_findings(scope, true)

    assert [finding] = open_findings(guest_id)
    assert finding.message =~ "kvm guest, but no reporting hypervisor defines a VM"
    assert finding.details["provider"] == "kvm"

    assert {[%{kind: "guest_without_vm", group: "health"}], 1} =
             Renga.Findings.list_findings(scope, domain: "collector")

    # Opting out resolves what was open.
    assert {:ok, false} = CollectorFindings.set_guest_without_vm_findings(scope, false)
    assert open_findings(guest_id) == []
  end

  test "a hypervisor reporting the domain resolves it", %{scope: scope, token: token} do
    {:ok, true} = CollectorFindings.set_guest_without_vm_findings(scope, true)

    # A host report refreshes its own machine as it commits.
    guest_id = guest!(token)
    assert [_finding] = open_findings(guest_id)

    hypervisor!(token, @uuid)
    assert open_findings(guest_id) == []
    assert [%{status: "resolved"}] = findings(guest_id)
  end

  test "only connected KVM guests with a UUID qualify", %{scope: scope, token: token} do
    {:ok, true} = CollectorFindings.set_guest_without_vm_findings(scope, true)

    bare_metal =
      guest!(token,
        environment: "bare_metal",
        uuid: Ecto.UUID.generate(),
        installation_id: Ecto.UUID.generate()
      )

    vmware =
      guest!(token,
        provider: "vmware",
        uuid: Ecto.UUID.generate(),
        installation_id: Ecto.UUID.generate()
      )

    no_uuid = guest!(token, uuid: nil, installation_id: Ecto.UUID.generate())

    unset_uuids =
      for uuid <- ~w(00000000-0000-0000-0000-000000000000 ffffffff-ffff-ffff-ffff-ffffffffffff) do
        guest!(token, uuid: uuid, installation_id: Ecto.UUID.generate())
      end

    guest_id = guest!(token)

    refresh!(scope)
    assert open_findings(bare_metal) == []
    assert open_findings(vmware) == []
    assert open_findings(no_uuid) == []
    assert Enum.all?(unset_uuids, &(open_findings(&1) == []))
    assert [_finding] = open_findings(guest_id)

    # The guest's agent disconnects.
    expired_at = DateTime.add(Renga.Time.utc_now_ms(), -1, :second)

    Repo.update_all(from(lease in AgentLease),
      set: [renewed_at: DateTime.add(expired_at, -90, :second), expires_at: expired_at]
    )

    refresh!(scope)
    assert open_findings(guest_id) == []
  end

  test "a heartbeat-only reconnection reopens the finding on the next sweep", %{
    scope: scope,
    token: token
  } do
    {:ok, true} = CollectorFindings.set_guest_without_vm_findings(scope, true)
    guest_id = guest!(token)
    assert [_finding] = open_findings(guest_id)

    agent = Repo.get_by!(Renga.Inventory.Agent, installation_id: @guest_installation)
    expired_at = DateTime.add(Renga.Time.utc_now_ms(), -1, :second)

    Repo.update_all(from(lease in AgentLease, where: lease.agent_id == ^agent.id),
      set: [renewed_at: DateTime.add(expired_at, -90, :second), expires_at: expired_at]
    )

    assert [{:ok, _}] = CollectorFindingsWorker.sweep()
    assert open_findings(guest_id) == []

    check_in!(token, @guest_installation)
    assert [{:ok, _}] = CollectorFindingsWorker.sweep()
    assert [_finding] = open_findings(guest_id)
  end

  describe "Collectors page" do
    test "owners opt in there", %{conn: conn, scope: scope, user: user} do
      conn =
        conn
        |> log_in_user(user)
        |> put_session(:current_organization_id, scope.organization_id)

      {:ok, view, _html} = live(conn, ~p"/settings/collectors")
      refute CollectorFindings.guest_without_vm_findings?(scope)

      view
      |> form("#guest-without-vm-form", guest_without_vm: %{enabled: "true"})
      |> render_change()

      assert CollectorFindings.guest_without_vm_findings?(scope)
      assert render(view) =~ "Guests without a VM will be flagged"
    end

    test "members see the setting without changing it", %{conn: conn, scope: scope} do
      member = user_fixture()
      organization_membership_fixture(member, scope.organization, %{role: "member"})

      conn =
        conn
        |> log_in_user(member)
        |> put_session(:current_organization_id, scope.organization_id)

      {:ok, view, _html} = live(conn, ~p"/settings/collectors")
      refute has_element?(view, "#guest-without-vm-form")
      assert has_element?(view, "#guest-without-vm-state", "Off")

      render_change(view, "set_guest_without_vm", %{"guest_without_vm" => %{"enabled" => "true"}})
      refute CollectorFindings.guest_without_vm_findings?(scope)
    end
  end

  defp refresh!(scope), do: {:ok, _} = CollectorFindings.refresh!(scope)

  defp open_findings(resource_id),
    do: Enum.filter(findings(resource_id), &(&1.status == "open"))

  defp findings(resource_id) do
    Repo.all(
      from finding in CollectorFinding,
        where: finding.resource_id == ^resource_id and finding.kind == "guest_without_vm"
    )
  end

  # A host agent's machine, by default a KVM guest with an SMBIOS UUID.
  defp guest!(token, opts \\ []) do
    identifiers =
      %{"machine_id" => "guest-#{System.unique_integer([:positive])}"}
      |> then(fn identifiers ->
        case Keyword.get(opts, :uuid, @uuid) do
          nil -> identifiers
          uuid -> Map.put(identifiers, "dmi_uuid", uuid)
        end
      end)

    virtualization =
      %{"kind" => "virtualization", "environment" => Keyword.get(opts, :environment, "vm_guest")}
      |> then(fn component ->
        if component["environment"] == "vm_guest",
          do: Map.put(component, "provider", Keyword.get(opts, :provider, "kvm")),
          else: component
      end)

    installation_id = Keyword.get(opts, :installation_id, @guest_installation)
    check_in!(token, installation_id)

    post!(token, installation_id, %{
      "observation_id" => "guest-#{System.unique_integer([:positive])}",
      "observed_at" => DateTime.to_iso8601(Renga.Time.utc_now_ms()),
      "resources" => [
        %{"kind" => "server", "identifiers" => identifiers, "components" => [virtualization]}
      ]
    })["reconciliation"]["matched_resource_id"]
  end

  defp hypervisor!(token, uuid) do
    post!(token, @hypervisor_installation, %{
      "observation_id" => "libvirt-#{System.unique_integer([:positive])}",
      "observed_at" => DateTime.to_iso8601(Renga.Time.utc_now_ms()),
      "scope" => "hypervisor",
      "collector" => %{"id" => "local-libvirt", "kind" => "vm_provider"},
      "hypervisor" => %{"id" => "qemu:///system", "status" => "reachable"},
      "complete" => true,
      "resources" => [
        %{
          "kind" => "vm",
          "identifiers" => %{"dmi_uuid" => uuid},
          "domain" => %{"name" => "web-1", "state" => "running", "persistent" => true}
        }
      ]
    })
  end

  defp check_in!(token, installation_id) do
    build_conn()
    |> put_req_header("authorization", "Bearer #{token}")
    |> put_req_header("x-renga-installation-id", installation_id)
    |> post(~p"/api/v1/agent/checkins", %{})
  end

  defp post!(token, installation_id, payload) do
    build_conn()
    |> put_req_header("authorization", "Bearer #{token}")
    |> put_req_header("x-renga-installation-id", installation_id)
    |> post(~p"/api/v1/observations", payload)
    |> valid_api_response(202)
  end
end
