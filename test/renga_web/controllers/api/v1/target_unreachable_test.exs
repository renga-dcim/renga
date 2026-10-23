defmodule RengaWeb.Api.V1.TargetUnreachableTest do
  @moduledoc """
  RFD 11 phase 4: the target-unreachable collector finding.
  """

  use RengaWeb.ConnCase, async: true

  import Ecto.Query
  import Renga.AccountsFixtures
  import Renga.InventoryFixtures

  alias Renga.Accounts
  alias Renga.Findings
  alias Renga.Inventory
  alias Renga.Inventory.CollectorFinding
  alias Renga.Inventory.CollectorFindings
  alias Renga.Inventory.CollectorFindingsWorker
  alias Renga.Repo

  @installation_id "67e55044-10b1-426f-9247-bb680e5fe0c8"
  @t0 ~U[2026-08-13 07:30:00.000000Z]

  setup do
    user = user_fixture()
    organization = organization_fixture()
    organization_membership_fixture(user, organization, %{role: "admin"})
    scope = Accounts.scope_for_user(user, organization.id)
    {:ok, {_key, token}} = Inventory.create_intake_api_key(scope, %{name: "Fleet"})

    %{scope: scope, token: token}
  end

  test "a switch silent past its window opens a finding on the switch", %{
    scope: scope,
    token: token
  } do
    switch_id = poll!(token, [reachable("10.0.0.1", "SER-1")], at: 0)
    poll!(token, [unreachable("10.0.0.1")], at: 15)
    poll!(token, [unreachable("10.0.0.1")], at: 30)

    # Not yet a whole window (45 minutes for a switch poller) since it answered.
    refresh!(scope, 44)
    assert open_findings(scope) == []

    poll!(token, [unreachable("10.0.0.1")], at: 45)
    refresh!(scope, 46)

    assert [finding] = open_findings(scope)
    assert finding.resource_id == switch_id

    assert finding.message ==
             "Collector core-switches has not reached 10.0.0.1 since 2026-08-13 07:30 UTC"

    assert %{
             "target" => "10.0.0.1",
             "collector_id" => "core-switches",
             "error" => "timeout",
             "window_seconds" => 2700
           } = finding.details

    assert finding.last_observed_at == at(45)

    # It answers again.
    poll!(token, [reachable("10.0.0.1", "SER-1")], at: 60)
    refresh!(scope, 61)
    assert open_findings(scope) == []
    assert [%{status: "resolved"}] = findings(scope)
  end

  test "a target never reached is filed on the installation's host", %{
    scope: scope,
    token: token
  } do
    host_id = host!(token)
    poll!(token, [unreachable("10.0.0.9")], at: 0)
    target_id = only_target_id(scope)

    # A target first reported moments ago has not been silent for a window.
    refresh!(scope, 1)
    assert open_findings(scope) == []

    backdate_target!(target_id, at(-60))
    refresh!(scope, 1)

    assert [finding] = open_findings(scope)
    assert finding.resource_id == host_id
    assert finding.target_id == target_id
    assert finding.message == "Collector core-switches has never reached 10.0.0.9"

    # Once it is reached and reports a switch, a later silence is the switch's.
    switch_id = poll!(token, [reachable("10.0.0.9", "SER-9")], at: 5)
    poll!(token, [unreachable("10.0.0.9")], at: 60)
    refresh!(scope, 61)

    assert [%{resource_id: ^switch_id}] = open_findings(scope)

    assert [%{resource_id: ^host_id, status: "resolved"}] =
             scope |> findings() |> Enum.filter(&(&1.status == "resolved"))
  end

  test "a target the stream stops reporting is no longer configured", %{
    scope: scope,
    token: token
  } do
    poll!(token, [reachable("10.0.0.1", "SER-1")], at: 0)
    poll!(token, [unreachable("10.0.0.1")], at: 50)
    refresh!(scope, 51)
    assert [_finding] = open_findings(scope)

    # The poller now reports only another target.
    poll!(token, [reachable("10.0.0.2", "SER-2")], at: 65)
    refresh!(scope, 96)
    assert open_findings(scope) == []
  end

  test "a hypervisor has a 15 minute window and shows no credentials", %{
    scope: scope,
    token: token
  } do
    host!(token)
    uri = "qemu+ssh://root:secret@hv-1/system"
    libvirt!(token, uri, "reachable", at: 0)
    libvirt!(token, uri, "unreachable", at: 10)
    refresh!(scope, 14)
    assert open_findings(scope) == []

    libvirt!(token, uri, "unreachable", at: 16)
    refresh!(scope, 16)

    assert [finding] = open_findings(scope)
    assert finding.details["target"] == "qemu+ssh://hv-1/system"
    refute inspect(finding) =~ "secret"
  end

  test "each target is its own finding in the Inbox", %{scope: scope, token: token} do
    switch_id =
      poll!(token, [reachable("10.0.0.1", "SER-1"), reachable("10.0.1.1", "SER-1")], at: 0)

    poll!(token, [unreachable("10.0.0.1"), unreachable("10.0.1.1")], at: 50)
    refresh!(scope, 51)

    assert {[first, second], 2} =
             Findings.list_findings(scope, domain: "collector", resource_id: switch_id)

    assert first.kind == "target_unreachable" and first.group == "health"
    assert first.resolution_key != second.resolution_key

    # Accepting one target as an exception leaves the other in the queue.
    {:ok, _workflow} =
      Findings.accept_exception(scope, first, %{"exception_reason" => "Decommissioning"})

    refresh!(scope, 52)
    assert {[remaining], 1} = Findings.list_findings(scope, domain: "collector")
    assert remaining.id == second.id
  end

  test "a report and the periodic sweep both refresh by the server's clock", %{
    scope: scope,
    token: token
  } do
    now = Renga.Time.utc_now_ms()
    recent = &DateTime.add(now, &1 * 60)

    poll!(token, [reachable("10.0.0.1", "SER-1")], at: recent.(-60))
    poll!(token, [unreachable("10.0.0.1")], at: recent.(-1))

    # The report's own refresh opened it.
    assert [finding] = open_findings(scope)

    Repo.update_all(from(f in CollectorFinding, where: f.id == ^finding.id),
      set: [status: "resolved", resolved_at: now]
    )

    CollectorFindingsWorker.sweep(now)
    assert [_reopened] = open_findings(scope)
  end

  defp refresh!(scope, minutes), do: {:ok, _} = CollectorFindings.refresh!(scope, at(minutes))

  defp open_findings(scope), do: Enum.filter(findings(scope), &(&1.status == "open"))

  defp findings(scope) do
    Repo.all(
      from finding in CollectorFinding,
        where: finding.organization_id == ^scope.organization_id,
        where: finding.kind == "target_unreachable",
        order_by: finding.inserted_at
    )
  end

  defp only_target_id(scope) do
    [target] =
      Repo.all(
        from t in Inventory.CollectorTarget, where: t.organization_id == ^scope.organization_id
      )

    target.id
  end

  # The target was first reported long ago.
  defp backdate_target!(target_id, at) do
    Repo.update_all(from(t in Inventory.CollectorTarget, where: t.id == ^target_id),
      set: [inserted_at: at]
    )
  end

  defp reachable(address, serial), do: {address, serial}
  defp unreachable(address), do: {address, nil}

  # Polls the targets, returning the first switch reported.
  defp poll!(token, targets, opts) do
    resources =
      for {address, serial} <- targets, serial do
        %{
          "kind" => "switch",
          "target" => address,
          "identifiers" => %{"serial_number" => serial},
          "attributes" => %{},
          "interfaces" => []
        }
      end

    response =
      post!(token, %{
        "observation_id" => "poll-#{System.unique_integer([:positive])}",
        "observed_at" => DateTime.to_iso8601(observed_at(opts)),
        "scope" => "targets",
        "collector" => %{"id" => "core-switches", "kind" => "switch_poller"},
        "targets" =>
          Enum.map(targets, fn
            {address, nil} ->
              %{"address" => address, "status" => "unreachable", "error" => "timeout"}

            {address, _serial} ->
              %{"address" => address, "status" => "reachable"}
          end),
        "complete" => true,
        "resources" => resources
      })

    case response["reconciliation"]["resources"] do
      [%{"resource_id" => id} | _rest] -> id
      _none -> nil
    end
  end

  defp libvirt!(token, uri, status, opts) do
    post!(token, %{
      "observation_id" => "libvirt-#{System.unique_integer([:positive])}",
      "observed_at" => DateTime.to_iso8601(observed_at(opts)),
      "scope" => "hypervisor",
      "collector" => %{"id" => "local-libvirt", "kind" => "vm_provider"},
      "hypervisor" => %{"id" => uri, "status" => status},
      "complete" => true,
      "resources" => []
    })
  end

  defp host!(token) do
    post!(token, %{
      "observation_id" => "host-1",
      "observed_at" => DateTime.to_iso8601(@t0),
      "resources" => [%{"kind" => "server", "identifiers" => %{"machine_id" => "poller-1"}}]
    })["reconciliation"]["matched_resource_id"]
  end

  defp post!(token, payload) do
    build_conn()
    |> put_req_header("authorization", "Bearer #{token}")
    |> put_req_header("x-renga-installation-id", @installation_id)
    |> post(~p"/api/v1/observations", payload)
    |> valid_api_response(202)
  end

  defp observed_at(opts) do
    case Keyword.fetch!(opts, :at) do
      %DateTime{} = at -> at
      minutes -> at(minutes)
    end
  end

  defp at(minutes), do: DateTime.add(@t0, minutes * 60)
end
