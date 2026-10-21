defmodule Renga.Power.LoadTest do
  use Renga.DataCase, async: true

  import Renga.AccountsFixtures
  import Renga.CatalogFixtures
  import Renga.InventoryFixtures

  alias Renga.Accounts
  alias Renga.DCIM
  alias Renga.Power
  alias Renga.Power.Cables
  alias Renga.Power.Load

  setup do
    organization = organization_fixture()
    user = user_fixture()
    organization_membership_fixture(user, organization, %{role: "owner"})
    scope = Accounts.scope_for_user(user, organization.id)

    {:ok, site} = DCIM.create_site(scope, %{name: "DC1"}, %{slug: "dc1"})
    {:ok, panel} = Power.create_panel(scope, %{site_id: site.id, name: "PDP-1"})
    %{scope: scope, panel: panel}
  end

  defp feed!(scope, panel, name, attrs) do
    {:ok, feed} =
      Power.create_feed(
        scope,
        panel.id,
        Map.merge(
          %{name: name, supply: "ac", phase: "single", voltage: "230", amperage: "16"},
          attrs
        )
      )

    feed
  end

  # A PDU whose inlet allocates a budget of its own, which must never count
  # on top of what is plugged into it. `legs` gives each outlet's leg.
  defp pdu!(scope, name, legs) do
    outlets =
      legs
      |> Enum.with_index(1)
      |> Enum.map(fn {leg, number} ->
        attributes =
          if leg, do: %{"inlet" => "Inlet", "feed_leg" => leg}, else: %{"inlet" => "Inlet"}

        %{kind: "power_outlet", name: "#{number}", attributes: attributes}
      end)

    inlet = %{kind: "power_port", name: "Inlet", attributes: %{"allocated_draw_w" => 9000}}
    {pdu, _expected} = assigned_server_fixture(scope, name, [inlet | outlets])
    %{ports: [inlet], outlets: outlets} = Power.list_device_endpoints(scope, pdu.id)
    {inlet, outlets}
  end

  defp port!(scope, name, attributes) do
    {server, _expected} =
      assigned_server_fixture(scope, name, [
        %{kind: "power_port", name: "PSU1", attributes: attributes}
      ])

    [port] = Power.list_device_endpoints(scope, server.id).ports
    port
  end

  defp plug!(scope, port, %Power.Outlet{} = outlet),
    do: {:ok, _} = Cables.connect(scope, %{power_port_id: port.id, power_outlet_id: outlet.id})

  defp plug!(scope, port, %Power.Feed{} = feed),
    do: {:ok, _} = Cables.connect(scope, %{power_port_id: port.id, power_feed_id: feed.id})

  defp load!(scope, feed, default \\ nil),
    do: Map.fetch!(Load.for_feeds(scope, [feed], default), feed.id)

  # A PDU whose hardware type names no inlet for any outlet: its inlet may
  # pass power on, so its own 9,000 W budget is neither a load nor zero.
  defp unmapped_pdu!(scope, name) do
    {pdu, _expected} =
      assigned_server_fixture(scope, name, [
        %{kind: "power_port", name: "Inlet", attributes: %{"allocated_draw_w" => 9000}},
        %{kind: "power_outlet", name: "1"}
      ])

    %{ports: [inlet], outlets: [outlet]} = Power.list_device_endpoints(scope, pdu.id)
    {inlet, outlet}
  end

  test "an inlet that may feed unmapped outlets is neither a load nor zero", context do
    %{scope: scope, panel: panel} = context
    feed = feed!(scope, panel, "A1", %{})
    {inlet, outlet} = unmapped_pdu!(scope, "rack-pdu")
    plug!(scope, inlet, feed)

    load = load!(scope, feed, Decimal.new(1))
    assert {load.draws, load.load, load.untraced?, load.status} == {[], nil, true, :unknown}
    assert Decimal.eq?(load.known, 0)

    # Something plugged in still cannot prove the 9,000 W budget an overload.
    plug!(scope, port!(scope, "web-1", %{"allocated_draw_w" => 230}), outlet)
    load = load!(scope, feed, Decimal.new(1))
    assert {load.draws, load.untraced?, load.status} == {[], true, :unknown}
    assert Decimal.eq?(load.known, 0)
  end

  test "converts each load with its own power factor, counting PDUs once", context do
    %{scope: scope, panel: panel} = context
    feed = feed!(scope, panel, "A1", %{})
    {inlet, [one, two]} = pdu!(scope, "rack-pdu", [nil, nil])
    plug!(scope, inlet, feed)

    plug!(
      scope,
      port!(scope, "web-1", %{"allocated_draw_w" => 400, "power_factor" => "0.8"}),
      one
    )

    plug!(scope, port!(scope, "web-2", %{"allocated_draw_w" => 300, "power_factor" => 0.75}), two)

    load = load!(scope, feed)

    assert Enum.map(load.draws, &{&1.port.resource.name, Decimal.to_integer(&1.va)}) == [
             {"web-1", 500},
             {"web-2", 400}
           ]

    # 230 V x 16 A x 80% = 2944 VA usable; the PDU's own 9000 W is not a load.
    assert Decimal.eq?(load.load, 900)
    assert Decimal.eq?(load.headroom, 2044)
    assert {load.status, load.uses_default?, Load.percent(load)} == {:ok, false, 31}
  end

  test "a load with no power factor is unknown until the default labels it", context do
    %{scope: scope, panel: panel} = context
    feed = feed!(scope, panel, "A1", %{})
    plug!(scope, port!(scope, "web-1", %{"allocated_draw_w" => 450}), feed)

    load = load!(scope, feed)
    assert {load.load, load.headroom, load.unconverted, load.status} == {nil, nil, 1, :unknown}

    {:ok, _organization} = Power.set_default_power_factor(scope, "0.9")
    load = Map.fetch!(Load.for_feeds(scope, [feed]), feed.id)

    assert Decimal.eq?(load.load, 500)
    assert {load.uses_default?, load.status} == {true, :ok}
    assert [%{power_factor: %{source: :organization_default}}] = load.draws
  end

  test "a load with no allocation leaves the feed unknown", context do
    %{scope: scope, panel: panel} = context
    feed = feed!(scope, panel, "A1", %{})
    {inlet, [one, two]} = pdu!(scope, "rack-pdu", [nil, nil])
    plug!(scope, inlet, feed)
    plug!(scope, port!(scope, "web-1", %{"allocated_draw_w" => 400, "power_factor" => 1}), one)
    plug!(scope, port!(scope, "web-2", %{"power_factor" => 1}), two)

    load = load!(scope, feed)

    assert {load.load, load.unallocated, load.status, Load.percent(load)} ==
             {nil, 1, :unknown, nil}

    assert Decimal.eq?(load.known, 400)
  end

  test "the default is not what an unallocated load rests on", context do
    %{scope: scope, panel: panel} = context
    feed = feed!(scope, panel, "A1", %{})
    plug!(scope, port!(scope, "lab-1", %{}), feed)

    load = load!(scope, feed, Decimal.new("0.9"))
    assert {load.unallocated, load.uses_default?, load.status} == {1, false, :unknown}
  end

  test "what is known can already prove a feed over its limit", context do
    %{scope: scope, panel: panel} = context
    feed = feed!(scope, panel, "A1", %{})
    {inlet, [one, two]} = pdu!(scope, "rack-pdu", [nil, nil])
    plug!(scope, inlet, feed)
    plug!(scope, port!(scope, "web-1", %{"allocated_draw_w" => 3000, "power_factor" => 1}), one)
    plug!(scope, port!(scope, "web-2", %{}), two)

    assert %Load{load: nil, status: :over} = load!(scope, feed)
  end

  test "a DC feed sums watts with no conversion", context do
    %{scope: scope, panel: panel} = context
    feed = feed!(scope, panel, "DC1", %{supply: "dc", voltage: "48", amperage: "50"})
    plug!(scope, port!(scope, "web-1", %{"allocated_draw_w" => 500}), feed)

    load = load!(scope, feed)
    # 48 V x 50 A x 80% = 1920 W usable.
    assert Decimal.eq?(load.load, 500) and Decimal.eq?(load.headroom, 1420)

    assert {load.capacity.unit, load.unconverted, load.uses_default?, load.status} ==
             {:w, 0, false, :ok}
  end

  test "reports an overloaded leg even when the feed has headroom", context do
    %{scope: scope, panel: panel} = context
    feed = feed!(scope, panel, "A1", %{phase: "three", voltage: "400", amperage: "32"})
    {inlet, [a, b, c]} = pdu!(scope, "rack-pdu", ["a", "b", "c"])
    plug!(scope, inlet, feed)
    plug!(scope, port!(scope, "db-1", %{"allocated_draw_w" => 5400, "power_factor" => "0.9"}), a)
    plug!(scope, port!(scope, "web-1", %{"allocated_draw_w" => 230, "power_factor" => 1}), b)
    plug!(scope, port!(scope, "web-2", %{"allocated_draw_w" => 230, "power_factor" => 1}), c)

    load = load!(scope, feed)

    # 6460 VA of about 17,737 VA usable, but leg A carries 6000 VA at
    # 400 / √3 = 230.9 V: 25.98 A against 32 A x 80% = 25.6 A.
    assert Decimal.eq?(load.load, 6460)
    assert Decimal.positive?(load.headroom)
    assert load.status == :over

    assert [leg_a, leg_b, leg_c] = load.legs

    assert {leg_a.leg, Decimal.round(leg_a.current, 2), leg_a.complete?} ==
             {"a", Decimal.new("25.98"), true}

    assert Decimal.gt?(leg_a.current, leg_a.limit) and Decimal.eq?(leg_a.limit, "25.6")
    assert Decimal.eq?(Decimal.round(leg_b.current, 2), "1.00")
    assert Decimal.eq?(leg_b.current, leg_c.current)
  end

  test "a load with no leg on a three-phase feed leaves leg coverage incomplete", context do
    %{scope: scope, panel: panel} = context
    feed = feed!(scope, panel, "A1", %{phase: "three", voltage: "400", amperage: "32"})
    {inlet, [a, unassigned]} = pdu!(scope, "rack-pdu", ["a", nil])
    plug!(scope, inlet, feed)
    plug!(scope, port!(scope, "web-1", %{"allocated_draw_w" => 230, "power_factor" => 1}), a)

    plug!(
      scope,
      port!(scope, "web-2", %{"allocated_draw_w" => 230, "power_factor" => 1}),
      unassigned
    )

    load = load!(scope, feed)
    assert Decimal.eq?(load.load, 460)
    assert {load.unassigned_legs, load.status} == {1, :unknown}
    assert Enum.all?(load.legs, &(not &1.complete?))
  end

  test "a leg comes from the PDU on the feed, not one further down", context do
    %{scope: scope, panel: panel} = context
    feed = feed!(scope, panel, "A1", %{phase: "three", voltage: "400", amperage: "32"})
    {floor_inlet, [_a, b]} = pdu!(scope, "floor-pdu", ["a", "b"])
    {rack_inlet, [rack_outlet]} = pdu!(scope, "rack-pdu", ["c"])
    plug!(scope, floor_inlet, feed)
    plug!(scope, rack_inlet, b)

    plug!(
      scope,
      port!(scope, "web-1", %{"allocated_draw_w" => 230, "power_factor" => 1}),
      rack_outlet
    )

    assert [%{leg: "b"}] = load!(scope, feed).draws
  end

  test "a PDU with nothing plugged in adds nothing", context do
    %{scope: scope, panel: panel} = context
    feed = feed!(scope, panel, "A1", %{})
    {inlet, _outlets} = pdu!(scope, "rack-pdu", [nil])
    plug!(scope, inlet, feed)

    load = load!(scope, feed)
    assert {load.draws, load.status} == {[], :ok}
    assert Decimal.eq?(load.load, 0)
  end

  test "an outlet in use with no named inlet leaves its feed incomplete", context do
    %{scope: scope, panel: panel} = context
    feed = feed!(scope, panel, "A1", %{})

    {pdu, _expected} =
      assigned_server_fixture(scope, "rack-pdu", [
        %{kind: "power_port", name: "Inlet"},
        %{kind: "power_outlet", name: "1", attributes: %{"inlet" => "Inlet"}},
        %{kind: "power_outlet", name: "2"}
      ])

    %{ports: [inlet], outlets: [mapped, unmapped]} = Power.list_device_endpoints(scope, pdu.id)
    plug!(scope, inlet, feed)
    plug!(scope, port!(scope, "web-1", %{"allocated_draw_w" => 230, "power_factor" => 1}), mapped)

    plug!(
      scope,
      port!(scope, "web-2", %{"allocated_draw_w" => 230, "power_factor" => 1}),
      unmapped
    )

    load = load!(scope, feed)
    assert {load.untraced?, load.load, load.status} == {true, nil, :unknown}
  end

  test "a chain deeper than any power train leaves its feed incomplete", context do
    %{scope: scope, panel: panel} = context
    feed = feed!(scope, panel, "A1", %{})
    pdus = Enum.map(1..8, &pdu!(scope, "pdu-#{&1}", [nil]))

    # pdu-1 on the feed, each next PDU on the one before, a server on the last.
    {first_inlet, _outlets} = hd(pdus)
    plug!(scope, first_inlet, feed)

    pdus
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.each(fn [{_inlet, [outlet]}, {next_inlet, _next}] ->
      plug!(scope, next_inlet, outlet)
    end)

    {_inlet, [last_outlet]} = List.last(pdus)

    plug!(
      scope,
      port!(scope, "web-1", %{"allocated_draw_w" => 230, "power_factor" => 1}),
      last_outlet
    )

    load = load!(scope, feed)
    assert {load.untraced?, load.status} == {true, :unknown}
  end

  test "loads every feed in one call", context do
    %{scope: scope, panel: panel} = context
    a = feed!(scope, panel, "A1", %{})
    b = feed!(scope, panel, "B1", %{})
    plug!(scope, port!(scope, "web-1", %{"allocated_draw_w" => 230, "power_factor" => 1}), a)

    loads = Load.for_feeds(scope, [a, b], nil)
    assert Decimal.eq?(loads[a.id].load, 230) and Decimal.eq?(loads[b.id].load, 0)
    assert Load.for_feeds(scope, []) == %{}
  end
end
