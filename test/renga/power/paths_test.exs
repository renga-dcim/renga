defmodule Renga.Power.PathsTest do
  use Renga.DataCase, async: true

  import Renga.AccountsFixtures
  import Renga.CatalogFixtures
  import Renga.InventoryFixtures

  alias Renga.Accounts
  alias Renga.DCIM
  alias Renga.Power
  alias Renga.Power.Cables
  alias Renga.Power.Paths

  setup do
    organization = organization_fixture()
    user = user_fixture()
    organization_membership_fixture(user, organization, %{role: "admin"})
    scope = Accounts.scope_for_user(user, organization.id)

    {:ok, site} = DCIM.create_site(scope, %{name: "DC1"}, %{slug: "dc1"})
    {:ok, panel} = Power.create_panel(scope, %{site_id: site.id, name: "PDP-1"})

    {:ok, feed} =
      Power.create_feed(scope, panel.id, %{
        name: "A1",
        side: "a",
        supply: "ac",
        phase: "single",
        voltage: "230",
        amperage: "16"
      })

    %{scope: scope, feed: feed}
  end

  defp pdu!(scope, name, outlet_attrs \\ %{"inlet" => "Inlet"}) do
    {pdu, _expected} =
      assigned_server_fixture(scope, name, [
        %{kind: "power_port", name: "Inlet"},
        %{kind: "power_outlet", name: "1", attributes: outlet_attrs},
        %{kind: "power_outlet", name: "2", attributes: outlet_attrs}
      ])

    %{ports: [inlet], outlets: outlets} = Power.list_device_endpoints(scope, pdu.id)
    {inlet, outlets}
  end

  defp server_ports!(scope) do
    {server, _expected} =
      assigned_server_fixture(scope, "web-1", [
        %{kind: "power_port", name: "PSU1"},
        %{kind: "power_port", name: "PSU2"}
      ])

    Power.list_device_endpoints(scope, server.id).ports
  end

  defp plug!(scope, port, %Power.Outlet{} = outlet),
    do: {:ok, _} = Cables.connect(scope, %{power_port_id: port.id, power_outlet_id: outlet.id})

  defp plug!(scope, port, %Power.Feed{} = feed),
    do: {:ok, _} = Cables.connect(scope, %{power_port_id: port.id, power_feed_id: feed.id})

  test "follows a port through rack and floor PDUs to the feed", context do
    %{scope: scope, feed: feed} = context
    {floor_inlet, [floor_outlet | _]} = pdu!(scope, "floor-pdu")
    {rack_inlet, [rack_outlet | _]} = pdu!(scope, "rack-pdu")
    [psu1, psu2] = server_ports!(scope)

    plug!(scope, floor_inlet, feed)
    plug!(scope, rack_inlet, floor_outlet)
    plug!(scope, psu1, rack_outlet)

    assert [complete, unplugged] = Paths.for_ports(scope, [psu1, psu2])

    assert Enum.map(complete.outlets, &{&1.resource.name, &1.name}) == [
             {"rack-pdu", "1"},
             {"floor-pdu", "1"}
           ]

    assert {complete.feed.name, complete.feed.panel.name, complete.stop} == {"A1", "PDP-1", nil}
    assert {unplugged.outlets, unplugged.feed, unplugged.stop} == {[], nil, :not_connected}
  end

  test "two ports sharing a PDU each get their own path", context do
    %{scope: scope, feed: feed} = context
    {inlet, [one, two]} = pdu!(scope, "rack-pdu")
    [psu1, psu2] = server_ports!(scope)

    plug!(scope, inlet, feed)
    plug!(scope, psu1, one)
    plug!(scope, psu2, two)

    assert [%{feed: %{id: id1}}, %{feed: %{id: id2}}] = Paths.for_ports(scope, [psu1, psu2])
    assert id1 == feed.id and id2 == feed.id
  end

  test "says where an incomplete path stops", %{scope: scope} do
    {_inlet, [outlet | _]} = pdu!(scope, "unfed-pdu")
    {_inlet, [unmapped | _]} = pdu!(scope, "unmapped-pdu", %{})
    [psu1, psu2] = server_ports!(scope)

    plug!(scope, psu1, outlet)
    plug!(scope, psu2, unmapped)

    assert [unfed, unknown] = Paths.for_ports(scope, [psu1, psu2])
    assert {unfed.stop, hd(unfed.outlets).inlet_port.name} == {:inlet_not_connected, "Inlet"}
    assert unknown.stop == :inlet_unknown
  end

  test "stops at a loop between PDUs", %{scope: scope} do
    {inlet_a, [outlet_a | _]} = pdu!(scope, "pdu-a")
    {inlet_b, [outlet_b | _]} = pdu!(scope, "pdu-b")

    plug!(scope, inlet_a, outlet_b)
    plug!(scope, inlet_b, outlet_a)

    assert [%{stop: :loop}] = Paths.for_ports(scope, [inlet_a])
  end
end
