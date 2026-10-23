defmodule Renga.Power.FindingReconcilerTest do
  use Renga.DataCase, async: true

  import Renga.AccountsFixtures
  import Renga.CatalogFixtures
  import Renga.InventoryFixtures
  import Renga.PowerReadingFixtures

  alias Renga.Accounts
  alias Renga.DCIM
  alias Renga.Findings
  alias Renga.Power
  alias Renga.Power.Cables
  alias Renga.Power.Finding
  alias Renga.Power.FindingReconciler
  alias Renga.Power.FindingSweeper

  setup do
    organization = organization_fixture()
    user = user_fixture()
    organization_membership_fixture(user, organization, %{role: "owner"})
    scope = Accounts.scope_for_user(user, organization.id)

    {:ok, site} = DCIM.create_site(scope, %{name: "DC1"}, %{slug: "dc1"})
    {:ok, panel} = Power.create_panel(scope, %{site_id: site.id, name: "PDP-1"})
    %{scope: scope, panel: panel, organization: organization}
  end

  defp feed!(scope, panel, name, side) do
    {:ok, feed} =
      Power.create_feed(scope, panel.id, %{
        name: name,
        supply: "ac",
        phase: "single",
        voltage: "230",
        amperage: "16",
        side: side
      })

    feed
  end

  defp server!(scope, name, ports, attributes \\ %{}) do
    {server, _expected} =
      assigned_server_fixture(
        scope,
        name,
        Enum.map(ports, &%{kind: "power_port", name: &1, attributes: attributes})
      )

    {server, Power.list_device_endpoints(scope, server.id).ports}
  end

  defp pdu!(scope, name, count) do
    outlets =
      for number <- 1..count,
          do: %{kind: "power_outlet", name: "#{number}", attributes: %{"inlet" => "Inlet"}}

    {pdu, _expected} =
      assigned_server_fixture(scope, name, [%{kind: "power_port", name: "Inlet"} | outlets])

    %{ports: [inlet], outlets: outlets} = Power.list_device_endpoints(scope, pdu.id)
    {pdu, inlet, outlets}
  end

  defp connect!(scope, port, %Power.Feed{} = feed),
    do: {:ok, _} = Cables.connect(scope, %{power_port_id: port.id, power_feed_id: feed.id})

  defp connect!(scope, port, %Power.Outlet{} = outlet),
    do: {:ok, _} = Cables.connect(scope, %{power_port_id: port.id, power_outlet_id: outlet.id})

  defp open_findings(scope) do
    {findings, _total} = Findings.list_findings(scope, domain: "power")
    Enum.map(findings, &{&1.resource.id, &1.kind, &1.resolution_key})
  end

  defp reconcile!(scope) do
    {:ok, counts} = FindingReconciler.reconcile(scope)
    counts
  end

  test "a device whose supplies reach one side is not redundant until they reach two",
       %{scope: scope, panel: panel} do
    a1 = feed!(scope, panel, "A1", "a")
    a2 = feed!(scope, panel, "A2", "a")
    {server, [psu1, psu2]} = server!(scope, "db-1", ["PSU1", "PSU2"])
    connect!(scope, psu1, a1)
    connect!(scope, psu2, a2)

    assert %{opened: 1} = reconcile!(scope)
    assert open_findings(scope) == [{server.id, "not_redundant", ""}]

    [finding] = elem(Findings.list_findings(scope, domain: "power"), 0)
    assert finding.message =~ "only side A"
    assert finding.group == "health"

    # Reconciling again keeps the one finding rather than opening another.
    assert %{opened: 0, kept: 1, resolved: 0} = reconcile!(scope)

    b1 = feed!(scope, panel, "B1", "b")
    connect!(scope, psu2, b1)
    assert %{resolved: 1} = reconcile!(scope)
    assert open_findings(scope) == []
  end

  test "a single-supply device is never a not-redundant finding", %{scope: scope, panel: panel} do
    {_server, [psu]} = server!(scope, "web-1", ["PSU1"])
    connect!(scope, psu, feed!(scope, panel, "A1", "a"))

    reconcile!(scope)
    assert open_findings(scope) == []
  end

  test "allocated and measured overloads are separate capacity findings", %{
    scope: scope,
    panel: panel,
    organization: organization
  } do
    feed = feed!(scope, panel, "A1", nil)
    # 4,000 W at unity is over the feed's 2,944 VA usable.
    {_pdu, inlet, [outlet | _rest]} = pdu!(scope, "rack-pdu", 1)
    connect!(scope, inlet, feed)

    {_server, [psu]} =
      server!(scope, "gpu-1", ["PSU1"], %{"allocated_draw_w" => 4000, "power_factor" => 1})

    connect!(scope, psu, outlet)

    reconcile!(scope)
    assert [{_, "feed_near_capacity", "allocated"}] = open_findings(scope)

    stream = power_stream_fixture(organization)
    pdu = Renga.Repo.get!(Renga.Inventory.Resource, inlet.resource_id)
    target_resource_fixture(stream, "10.0.0.5", pdu)

    reading_fixture(stream,
      target: "10.0.0.5",
      boundary: "feed",
      quantity: "apparent_power",
      coverage: "complete",
      value: 3100
    )

    reconcile!(scope)

    assert open_findings(scope) |> Enum.map(&elem(&1, 2)) |> Enum.sort() ==
             ["allocated", "measured"]
  end

  test "a supply reporting no input opens a finding until it reports ok", %{
    scope: scope,
    organization: organization
  } do
    {server, _ports} = server!(scope, "db-1", ["PSU1", "PSU2"])
    stream = power_stream_fixture(organization, "bmc_power")
    target_resource_fixture(stream, "bmc-db-1", server)

    state = fn state, event_at ->
      reading_fixture(stream,
        target: "bmc-db-1",
        sensor: "psu2-state",
        boundary: "supply_input",
        quantity: "state",
        unit: nil,
        state: state,
        component: {"power_port", "PSU2"},
        event_at: event_at
      )
    end

    now = Renga.Time.utc_now_ms()
    state.("no_input", DateTime.add(now, -10, :second))
    reconcile!(scope)
    assert [{_, "supply_failed", "PSU2"}] = open_findings(scope)

    state.("ok", now)
    reconcile!(scope)
    assert open_findings(scope) == []
  end

  test "a supply failing in several windows is one finding, and others still open", %{
    scope: scope,
    panel: panel,
    organization: organization
  } do
    {server, _ports} = server!(scope, "db-2", ["PSU1", "PSU2"])
    stream = power_stream_fixture(organization, "bmc_power")
    target_resource_fixture(stream, "bmc-db-2", server)

    for window <- [0, 60] do
      reading_fixture(stream,
        target: "bmc-db-2",
        sensor: "psu2-state-#{window}",
        boundary: "supply_input",
        quantity: "state",
        unit: nil,
        state: "failed",
        component: {"power_port", "PSU2"},
        window_seconds: window
      )
    end

    # An unrelated finding in the same reconciliation.
    {_single, [psu]} = server!(scope, "web-9", ["PSU1"])
    {_other, [a, b]} = server!(scope, "db-3", ["PSU1", "PSU2"])
    connect!(scope, a, feed!(scope, panel, "A1", "a"))
    connect!(scope, b, feed!(scope, panel, "A2", "a"))
    connect!(scope, psu, feed!(scope, panel, "B1", "b"))

    assert %{opened: 2, kept: 0} = reconcile!(scope)
    findings = open_findings(scope)
    assert [{_, "supply_failed", "PSU2"}] = for({_, "supply_failed", _} = f <- findings, do: f)
    assert Enum.any?(findings, &match?({_, "not_redundant", _}, &1))

    assert %{opened: 0, kept: 2} = reconcile!(scope)
  end

  test "a supply failure needs no modeled power port", %{
    scope: scope,
    organization: organization
  } do
    {server, []} = server!(scope, "untyped-1", [])
    stream = power_stream_fixture(organization, "bmc_power")
    target_resource_fixture(stream, "bmc-untyped-1", server)

    state = fn state ->
      reading_fixture(stream,
        target: "bmc-untyped-1",
        sensor: "psu1-state",
        boundary: "supply_input",
        quantity: "state",
        unit: nil,
        state: state,
        component: {"power_port", "PSU1"},
        event_at: Renga.Time.utc_now_ms()
      )
    end

    state.("no_input")
    reconcile!(scope)
    assert [{server.id, "supply_failed", "PSU1"}] == open_findings(scope)

    state.("ok")
    reconcile!(scope)
    assert open_findings(scope) == []
  end

  test "an outlet drawing power with nothing connected is unexpected draw", %{
    scope: scope,
    organization: organization
  } do
    {pdu, _inlet, [one, two, three]} = pdu!(scope, "rack-pdu", 3)
    {_server, [psu]} = server!(scope, "web-1", ["PSU1"])
    connect!(scope, psu, one)
    stream = power_stream_fixture(organization)
    target_resource_fixture(stream, "10.0.0.5", pdu)

    for {outlet, value} <- [{one, 200}, {two, 120}, {three, 2}] do
      reading_fixture(stream,
        target: "10.0.0.5",
        sensor: "outlet/#{outlet.name}",
        boundary: "outlet",
        component: {"power_outlet", outlet.name},
        value: value
      )
    end

    reconcile!(scope)
    assert {pdu.id, "unexpected_draw", two.id} in open_findings(scope)
    assert [_one] = for({_, "unexpected_draw", _} = finding <- open_findings(scope), do: finding)

    {[finding], 1} = Findings.list_findings(scope, domain: "power", kind: "unexpected_draw")
    assert finding.message == "Outlet 2 draws 120 W with no connection recorded."
    assert finding.group == "drift"
  end

  test "a port plugged into a PDU with no feed has an incomplete path", %{scope: scope} do
    {_pdu, _inlet, [outlet]} = pdu!(scope, "rack-pdu", 1)
    {server, [psu]} = server!(scope, "web-1", ["PSU1"])
    connect!(scope, psu, outlet)

    reconcile!(scope)
    assert open_findings(scope) == [{server.id, "path_incomplete", psu.id}]
    assert [%Finding{details: %{"stop" => "inlet_not_connected"}}] = Repo.all(Finding)
  end

  test "the sweeper reconciles every organization with power data", %{scope: scope, panel: panel} do
    {_server, [psu1, psu2]} = server!(scope, "db-1", ["PSU1", "PSU2"])
    connect!(scope, psu1, feed!(scope, panel, "A1", "a"))
    connect!(scope, psu2, feed!(scope, panel, "A2", "a"))

    FindingSweeper.sweep()
    assert [{_, "not_redundant", ""}] = open_findings(scope)
  end
end
