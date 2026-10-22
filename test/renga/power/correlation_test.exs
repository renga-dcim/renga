defmodule Renga.Power.CorrelationTest do
  use Renga.DataCase, async: true

  import Renga.AccountsFixtures
  import Renga.CatalogFixtures
  import Renga.InventoryFixtures
  import Renga.PowerReadingFixtures

  alias Renga.Accounts
  alias Renga.DCIM
  alias Renga.DCIM.CurrentPlacement
  alias Renga.Findings
  alias Renga.Power
  alias Renga.Power.Cables
  alias Renga.Power.Correlation
  alias Renga.Power.CorrelationSample
  alias Renga.Power.FindingReconciler

  setup do
    organization = organization_fixture()
    user = user_fixture()
    organization_membership_fixture(user, organization, %{role: "owner"})
    scope = Accounts.scope_for_user(user, organization.id)
    {:ok, site} = DCIM.create_site(scope, %{name: "DC1"}, %{slug: "dc1"})
    {:ok, rack} = DCIM.create_rack(scope, %{name: "R1"}, %{site_id: site.id, height_units: 42})

    {pdu, _expected} =
      assigned_server_fixture(scope, "pdu-a1", [
        %{kind: "power_port", name: "Inlet"}
        | for(
            n <- 1..4,
            do: %{kind: "power_outlet", name: "#{n}", attributes: %{"inlet" => "Inlet"}}
          )
      ])

    place!(scope, pdu, rack)
    %{outlets: outlets} = Power.list_device_endpoints(scope, pdu.id)
    pdus = power_stream_fixture(organization)
    target_resource_fixture(pdus, "10.0.0.5", pdu)
    # Readings from one hour ago onwards, a minute apart.
    start = DateTime.add(Renga.Time.utc_now_ms(), -3_600, :second)

    %{
      scope: scope,
      organization: organization,
      site: site,
      rack: rack,
      pdu: pdu,
      pdus: pdus,
      outlets: Map.new(outlets, &{&1.name, &1}),
      start: start
    }
  end

  defp place!(scope, resource, rack) do
    Repo.insert!(%CurrentPlacement{
      organization_id: scope.organization_id,
      resource_id: resource.id,
      site_id: rack.site_id,
      rack_id: rack.id
    })
  end

  # A one-supply server in the rack whose BMC reports it at `target`.
  defp server!(%{scope: scope, organization: organization, rack: rack}, name, target) do
    {server, _expected} =
      assigned_server_fixture(scope, name, [%{kind: "power_port", name: "PSU1"}])

    place!(scope, server, rack)
    bmcs = power_stream_fixture(organization, "bmc_power")
    target_resource_fixture(bmcs, target, server)
    %{ports: [psu]} = Power.list_device_endpoints(scope, server.id)
    %{server: server, psu: psu, stream: bmcs, target: target}
  end

  defp sample(attrs) do
    attrs = Map.new(attrs)
    quantity = Map.get(attrs, :quantity, "real_power")
    event_at = Map.fetch!(attrs, :event_at)

    %{
      target: Map.get(attrs, :target),
      sensor: Map.fetch!(attrs, :sensor),
      boundary: Map.fetch!(attrs, :boundary),
      quantity: quantity,
      unit:
        if(quantity == "state", do: nil, else: Map.get(Renga.Power.Reading.units(), quantity)),
      leg: nil,
      component: Map.get(attrs, :component),
      coverage: nil,
      origin: "native",
      status: Map.get(attrs, :status, "valid"),
      value: Map.get(attrs, :value),
      state: Map.get(attrs, :state),
      window_start: event_at,
      window_end: event_at,
      event_at: event_at,
      mapping_name: "test",
      mapping_version: 1,
      fresh_for_seconds: 180
    }
  end

  defp outlet_samples(target, outlet, values, start, offset \\ 5) do
    for {value, minute} <- Enum.with_index(values) do
      sample(
        target: target,
        sensor: "outlet/#{outlet}",
        boundary: "outlet",
        component: %{kind: "power_outlet", name: outlet},
        value: value,
        event_at: DateTime.add(start, minute * 60 + offset, :second)
      )
    end
  end

  defp supply_samples(%{target: target}, values, start, offset \\ 20) do
    for {value, minute} <- Enum.with_index(values) do
      sample(
        target: target,
        sensor: "PSU1/input",
        boundary: "supply_input",
        component: %{kind: "power_port", name: "PSU1"},
        value: value,
        event_at: DateTime.add(start, minute * 60 + offset, :second)
      )
    end
  end

  defp state_samples(target, boundary, sensor, component, states, start, offset) do
    for {state, minute} <- Enum.with_index(states) do
      sample(
        target: target,
        sensor: sensor,
        boundary: boundary,
        component: component,
        quantity: "state",
        state: state,
        event_at: DateTime.add(start, minute * 60 + offset, :second)
      )
    end
  end

  defp record!(source, samples), do: Correlation.record!(source, samples, Renga.Time.utc_now_ms())

  # A load that steps between two levels every `every` minutes.
  defp steps(low, high, every, shift \\ 0) do
    for minute <- 0..59, do: if(rem(div(minute + shift, every), 2) == 0, do: low, else: high)
  end

  defp suggestions(scope) do
    {findings, _total} =
      Findings.list_findings(scope, domain: "power", kind: "suggested_connection")

    findings
  end

  test "a supply whose input moves with an outlet's draw is suggested for that outlet", context do
    %{scope: scope, pdus: pdus, outlets: outlets, start: start} = context
    web = server!(context, "web-1", "bmc-web-1")
    db = server!(context, "db-1", "bmc-db-1")
    web_load = steps(200, 320, 10)
    db_load = steps(150, 230, 12, 5)

    record!(pdus, outlet_samples("10.0.0.5", "2", Enum.map(web_load, &(&1 * 1.04)), start))
    record!(pdus, outlet_samples("10.0.0.5", "3", Enum.map(db_load, &(&1 * 1.03)), start))
    record!(web.stream, supply_samples(web, web_load, start))
    record!(db.stream, supply_samples(db, db_load, start))

    {:ok, %{opened: 2}} = FindingReconciler.reconcile(scope)

    by_port = Map.new(suggestions(scope), &{&1.details["port_id"], &1})
    web_finding = Map.fetch!(by_port, web.psu.id)
    assert web_finding.details["outlet_id"] == outlets["2"].id
    assert web_finding.resource.id == web.server.id
    assert web_finding.group == "drift"
    assert web_finding.details["basis"] == "load"
    assert web_finding.details["score"] > 0.99

    assert web_finding.message ==
             "PSU1 may be plugged into pdu-a1 outlet 2. Their readings rose and fell together " <>
               "at 5 distinct times."

    # The evidence names the paired samples, before and after each change.
    [%{"outlet" => [before, later], "supply" => [supply_before, _supply_later]} | _] =
      web_finding.details["steps"]

    assert before["sensor"] == "outlet/2" and before["boundary"] == "outlet"
    assert before["source_id"] == pdus.id and before["target"] == "10.0.0.5"
    assert {before["value"], later["value"]} == {"208", "332.8"}
    assert supply_before["boundary"] == "supply_input"

    assert Map.fetch!(by_port, db.psu.id).details["outlet_id"] == outlets["3"].id
  end

  test "an ambiguous or common-mode match suggests nothing", context do
    %{scope: scope, pdus: pdus, start: start} = context
    web = server!(context, "web-1", "bmc-web-1")
    twin = server!(context, "web-2", "bmc-web-2")
    load = steps(200, 320, 10)

    # Two supplies track outlet 2 equally well.
    record!(pdus, outlet_samples("10.0.0.5", "2", load, start))
    record!(web.stream, supply_samples(web, load, start))
    record!(twin.stream, supply_samples(twin, Enum.map(load, &(&1 + 3)), start))

    {:ok, _counts} = FindingReconciler.reconcile(scope)
    assert suggestions(scope) == []

    # Every series in the rack steps together, as on a feed-wide event.
    third = server!(context, "web-3", "bmc-web-3")
    record!(pdus, outlet_samples("10.0.0.5", "3", Enum.map(load, &(&1 * 2)), start))
    record!(pdus, outlet_samples("10.0.0.5", "4", Enum.map(load, &(&1 * 3)), start))
    record!(third.stream, supply_samples(third, Enum.map(load, &(&1 * 2)), start))

    {:ok, _counts} = FindingReconciler.reconcile(scope)
    assert suggestions(scope) == []
  end

  test "an outlet that turns off as one supply loses input is suggested until connected",
       context do
    %{scope: scope, pdus: pdus, outlets: outlets, start: start} = context
    web = server!(context, "web-1", "bmc-web-1")

    record!(
      pdus,
      state_samples(
        "10.0.0.5",
        "outlet",
        "outlet/3",
        %{kind: "power_outlet", name: "3"},
        ~w(on on off),
        start,
        5
      )
    )

    record!(
      web.stream,
      state_samples(
        web.target,
        "supply_input",
        "PSU1/input",
        %{kind: "power_port", name: "PSU1"},
        ~w(ok ok no_input),
        start,
        40
      )
    )

    {:ok, %{opened: 1}} = FindingReconciler.reconcile(scope)
    [finding] = suggestions(scope)
    assert finding.details["basis"] == "state"
    assert finding.details["outlet_id"] == outlets["3"].id
    assert finding.message =~ "lost its draw as the supply lost input"

    [%{"outlet" => [on, off], "supply" => [ok, no_input]}] = finding.details["steps"]

    assert {on["state"], off["state"], ok["state"], no_input["state"]} ==
             {"on", "off", "ok", "no_input"}

    # The evidence outlives the window.
    tomorrow = DateTime.add(Renga.Time.utc_now_ms(), 2, :day)
    {:ok, %{kept: 1}} = FindingReconciler.reconcile(scope, tomorrow)
    assert Repo.aggregate(CorrelationSample, :count) == 0
    assert [%{details: details}] = suggestions(scope)
    assert details == finding.details

    # Recording the connection, which only a person does, resolves it.
    {:ok, _assertion} =
      Cables.connect(scope, %{power_port_id: web.psu.id, power_outlet_id: outlets["3"].id})

    {:ok, %{resolved: 1}} = FindingReconciler.reconcile(scope)
    assert suggestions(scope) == []
  end

  test "a connected outlet or supply is never suggested", context do
    %{scope: scope, pdus: pdus, outlets: outlets, start: start} = context
    web = server!(context, "web-1", "bmc-web-1")
    load = steps(200, 320, 10)

    {:ok, _assertion} =
      Cables.connect(scope, %{power_port_id: web.psu.id, power_outlet_id: outlets["1"].id})

    record!(pdus, outlet_samples("10.0.0.5", "2", load, start))
    record!(web.stream, supply_samples(web, load, start))

    {:ok, _counts} = FindingReconciler.reconcile(scope)
    assert suggestions(scope) == []
  end

  test "keeps one valid sample per series and minute, within the window", %{pdus: pdus} do
    now = Renga.Time.utc_now_ms()
    minute = %{now | second: 0, microsecond: {0, 6}}

    outlet = fn attrs ->
      sample(
        Keyword.merge(
          [
            target: "10.0.0.5",
            sensor: "outlet/1",
            boundary: "outlet",
            value: 100,
            component: %{kind: "power_outlet", name: "1"}
          ],
          attrs
        )
      )
    end

    Correlation.record!(
      pdus,
      [
        outlet.(event_at: DateTime.add(minute, 10, :second), value: 100),
        outlet.(event_at: DateTime.add(minute, 40, :second), value: 140),
        outlet.(event_at: DateTime.add(minute, 20, :second), value: 120),
        outlet.(event_at: DateTime.add(minute, -50, :second), status: "failed", value: nil),
        outlet.(event_at: DateTime.add(now, -2, :day)),
        outlet.(event_at: now, boundary: "feed", component: nil),
        outlet.(event_at: now, quantity: "power_factor", value: 0.9)
      ],
      now
    )

    assert [%CorrelationSample{value: value}] = Repo.all(CorrelationSample)
    assert Decimal.equal?(value, 140)
  end
end
