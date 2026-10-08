defmodule RengaWeb.InboxLiveTest do
  # The real expiry timer test holds its fixture transaction for 30 seconds.
  use RengaWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Renga.AccountsFixtures
  import Renga.FindingsFixtures
  import Renga.InventoryFixtures

  alias Renga.DCIM.PlacementFinding
  alias Renga.Findings
  alias Renga.Inventory

  setup %{conn: conn} do
    organization = organization_fixture()
    user = user_fixture()
    organization_membership_fixture(user, organization, %{role: "member"})
    scope = Renga.Accounts.scope_for_user(user, organization.id)
    admin = admin_scope(organization)

    {:ok, resource} = Inventory.create_resource(admin, %{kind: "server", name: "web-01"})
    {:ok, interface} = Inventory.create_interface(admin, resource.id, %{name: "eth0"})

    %{
      conn: log_in(conn, user, organization),
      organization: organization,
      scope: scope,
      resource: resource,
      interface: interface
    }
  end

  test "lists every domain in one queue grouped as Drift and Health", %{
    conn: conn,
    resource: resource,
    interface: interface
  } do
    drift = component_finding_fixture(resource, "component_drift")
    placement = resource_finding_fixture(PlacementFinding, resource, "unknown_location")
    topology = topology_finding_fixture(interface, "missing_vlan")

    {:ok, view, _html} = live(conn, ~p"/inbox")

    assert has_element?(view, "#findings-group-drift", "Drift")
    assert has_element?(view, "#findings-group-health", "Health")
    assert has_element?(view, "#findings-#{drift.id}", "Component drift")
    assert has_element?(view, "#findings-#{topology.id}", "eth0")
    assert has_element?(view, "#findings-#{placement.id}", "web-01")
    assert has_element?(view, "#inbox-group-drift", "2")
    assert has_element?(view, "#inbox-group-health", "1")

    view |> element("#inbox-group-health") |> render_click()

    assert_patch(view, ~p"/inbox?group=health")
    assert has_element?(view, "#findings-#{placement.id}")
    refute has_element?(view, "#findings-#{drift.id}")
  end

  test "retired findings pages land on the queue filtered to their domain", %{
    conn: conn,
    resource: resource,
    interface: interface
  } do
    drift = component_finding_fixture(resource, "component_drift")
    topology = topology_finding_fixture(interface, "missing_vlan")

    {:ok, view, _html} =
      conn
      |> get(~p"/inbox/topology?interface_id=#{interface.id}")
      |> redirected_to(301)
      |> then(&live(conn, &1))

    assert has_element?(view, "#findings-#{topology.id}")
    refute has_element?(view, "#findings-#{drift.id}")
    assert has_element?(view, "#inbox-clear-scope", "One interface")
  end

  test "legacy topology filters preserve resolved and all-kind semantics", context do
    open = topology_finding_fixture(context.interface, "missing_vlan")
    resolved = topology_finding_fixture(context.interface, "unexpected_vlan", key: "resolved")

    Renga.Repo.update!(
      Ecto.Changeset.change(resolved, status: "resolved", resolved_at: DateTime.utc_now())
    )

    for route <- ["/inbox/topology", "/network/topology-findings"] do
      target =
        context.conn
        |> get("#{route}?status=resolved&kind=all&interface_id=#{context.interface.id}")
        |> redirected_to(301)

      {:ok, view, _} = live(context.conn, target)
      assert has_element?(view, "#findings-#{resolved.id}")
      refute has_element?(view, "#findings-#{open.id}")
      {:ok, view, _} = live(context.conn, target <> "&state=open")
      assert has_element?(view, "#findings-#{open.id}")
      refute has_element?(view, "#findings-#{resolved.id}")
    end
  end

  test "diagnostics distinguish occurrences including resolved snapshots", context do
    for {key, remote, status} <- [{"a", "remote-a", "open"}, {"b", "remote-b", "resolved"}] do
      row = topology_finding_fixture(context.interface, "ambiguous_neighbor", key: key)

      Renga.Repo.update!(
        Ecto.Changeset.change(row,
          details: %{"chassis_id" => remote},
          status: status,
          resolved_at: if(status == "resolved", do: DateTime.utc_now())
        )
      )

      {:ok, view, _} = live(context.conn, ~p"/inbox?#{[finding: "topology:#{row.id}"]}")
      assert has_element?(view, "#finding-details", remote)

      refute has_element?(
               view,
               "#finding-details",
               if(remote == "remote-a", do: "remote-b", else: "remote-a")
             )
    end
  end

  @tag timeout: 45_000
  test "idle connected views refresh timed workflow expiry without broadcasts", context do
    snoozed = component_finding_fixture(context.resource, "component_drift")
    excepted = component_finding_fixture(context.resource, "missing_expected_component", key: "b")
    until = DateTime.add(Renga.Time.utc_now_ms(), 1)

    {:ok, _} =
      Findings.snooze(
        context.scope,
        Findings.get_finding!(context.scope, "component", snoozed.id),
        until
      )

    {:ok, _} =
      Findings.accept_exception(
        context.scope,
        Findings.get_finding!(context.scope, "component", excepted.id),
        %{"exception_reason" => "Temporary", "exception_expires_at" => until}
      )

    {:ok, view, _} = live(context.conn, ~p"/inbox?#{[finding: "component:#{excepted.id}"]}")
    {:ok, resource_view, _} = live(context.conn, ~p"/inventory/#{context.resource.id}")
    refute has_element?(view, "#findings-#{snoozed.id}")
    assert has_element?(view, "#finding-state", "Exception")
    assert has_element?(resource_view, "#resource-exceptions", "Temporary")
    assert eventually(fn -> has_element?(view, "#findings-#{snoozed.id}") end, 640)
    assert has_element?(view, "#findings-#{excepted.id}")
    assert has_element?(view, "#finding-state", "Open")
    assert has_element?(view, "#inbox-group-drift", "2")

    assert eventually(fn ->
             not has_element?(resource_view, "#resource-exceptions", "Temporary")
           end)
  end

  test "a member assigns, snoozes, and accepts a finding as an exception", %{
    conn: conn,
    scope: scope,
    resource: resource
  } do
    finding = component_finding_fixture(resource, "component_drift")
    path = ~p"/inbox?#{[finding: "component:#{finding.id}"]}"

    {:ok, view, _html} = live(conn, path)

    assert has_element?(view, "#finding-panel", "Component drift")
    assert has_element?(view, "#finding-properties", "web-01")

    view |> element("#finding-assign-me") |> render_click()
    assert has_element?(view, "#findings-#{finding.id} [data-assignee]", scope.user.email)
    assert has_element?(view, "#finding-history", "Assigned to #{scope.user.email}")

    view |> element("#finding-snooze-1h") |> render_click()
    assert has_element?(view, "#finding-state", "Snoozed")
    refute has_element?(view, "#findings-#{finding.id}")

    view |> element("#finding-wake") |> render_click()
    assert has_element?(view, "#findings-#{finding.id}")

    view
    |> form("#finding-exception-form", exception: %{exception_reason: " "})
    |> render_submit()

    assert has_element?(view, "#finding-exception-form", "explain why this is acceptable")

    view
    |> form("#finding-exception-form",
      exception: %{exception_reason: "Lab chassis, known gap", expires: "30"}
    )
    |> render_submit()

    assert has_element?(view, "#finding-exception", "Lab chassis, known gap")
    refute has_element?(view, "#findings-#{finding.id}")

    {:ok, excepted, _html} = live(conn, ~p"/inbox?state=excepted")
    assert has_element?(excepted, "#findings-#{finding.id} [data-state=excepted]")

    view |> element("#finding-exception-remove") |> render_click()
    assert has_element?(view, "#findings-#{finding.id}")
    assert has_element?(view, "#finding-state", "Open")
  end

  test "filters to my findings and unassigned findings", %{
    conn: conn,
    scope: scope,
    resource: resource
  } do
    mine = component_finding_fixture(resource, "component_drift")
    other = component_finding_fixture(resource, "missing_expected_component", key: "x")
    {[mine_finding], 1} = Findings.list_findings(scope, kind: "component_drift")
    {:ok, _workflow} = Findings.assign(scope, mine_finding, scope.user.id)

    {:ok, view, _html} = live(conn, ~p"/inbox?assignee=me")
    assert has_element?(view, "#findings-#{mine.id}")
    refute has_element?(view, "#findings-#{other.id}")

    {:ok, view, _html} = live(conn, ~p"/inbox?assignee=unassigned")
    assert has_element?(view, "#findings-#{other.id}")
    refute has_element?(view, "#findings-#{mine.id}")
  end

  test "viewers read findings but cannot change them, even with forged events", %{
    organization: organization,
    resource: resource
  } do
    finding = component_finding_fixture(resource, "component_drift")
    viewer = user_fixture()
    organization_membership_fixture(viewer, organization, %{role: "viewer"})

    {:ok, view, _html} =
      build_conn()
      |> log_in(viewer, organization)
      |> live(~p"/inbox?#{[finding: "component:#{finding.id}"]}")

    assert has_element?(view, "#finding-panel", "Component drift")
    assert has_element?(view, "#finding-actions-unavailable")
    refute has_element?(view, "#finding-actions")

    assert render_click(view, "assign_me", %{}) =~ "requires the member role"
    assert {[%{workflow: nil}], 1} = Findings.list_findings(admin_scope(organization))
  end

  test "never shows or opens another organization's findings", %{conn: conn} do
    other = organization_fixture()
    {:ok, resource} = Inventory.create_resource(admin_scope(other), %{kind: "server", name: "x"})
    hidden = component_finding_fixture(resource, "component_drift")

    {:ok, view, _html} = live(conn, ~p"/inbox?#{[finding: "component:#{hidden.id}"]}")

    refute has_element?(view, "#findings-#{hidden.id}")
    refute has_element?(view, "#finding-panel")
    assert has_element?(view, "#findings-empty")
  end

  test "updates when findings change elsewhere", %{conn: conn, scope: scope, resource: resource} do
    {:ok, view, _html} = live(conn, ~p"/inbox")
    finding = component_finding_fixture(resource, "component_drift")
    {[found], 1} = Findings.list_findings(scope)
    {:ok, _workflow} = Findings.assign(scope, found, scope.user.id)

    assert eventually(fn -> has_element?(view, "#findings-#{finding.id} [data-assignee]") end)
  end

  defp log_in(conn, user, organization) do
    conn
    |> log_in_user(user)
    |> put_session(:current_organization_id, organization.id)
  end

  defp admin_scope(organization) do
    admin = user_fixture()
    organization_membership_fixture(admin, organization, %{role: "admin"})
    Renga.Accounts.scope_for_user(admin, organization.id)
  end

  defp eventually(fun, attempts \\ 20) do
    cond do
      fun.() -> true
      attempts == 0 -> false
      true -> Process.sleep(50) && eventually(fun, attempts - 1)
    end
  end
end
