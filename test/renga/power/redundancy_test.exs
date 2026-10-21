defmodule Renga.Power.RedundancyTest do
  use Renga.DataCase, async: true

  import Renga.AccountsFixtures
  import Renga.CatalogFixtures
  import Renga.InventoryFixtures

  alias Renga.Accounts
  alias Renga.DCIM
  alias Renga.Power
  alias Renga.Power.Cables
  alias Renga.Power.Paths
  alias Renga.Power.Redundancy

  setup do
    organization = organization_fixture()
    user = user_fixture()
    organization_membership_fixture(user, organization, %{role: "admin"})
    scope = Accounts.scope_for_user(user, organization.id)

    {:ok, site} = DCIM.create_site(scope, %{name: "DC1"}, %{slug: "dc1"})
    {:ok, panel} = Power.create_panel(scope, %{site_id: site.id, name: "PDP-1"})

    feed = fn name, side ->
      {:ok, feed} =
        Power.create_feed(scope, panel.id, %{
          name: name,
          side: side,
          phase: "single",
          voltage: "230",
          amperage: "16"
        })

      feed
    end

    %{
      scope: scope,
      a1: feed.("A1", "a"),
      a2: feed.("A2", "a"),
      b1: feed.("B1", "b"),
      n1: feed.("N1", nil)
    }
  end

  defp ports!(scope, name, count) do
    {server, _expected} =
      assigned_server_fixture(
        scope,
        name,
        for(n <- 1..count, do: %{kind: "power_port", name: "PSU#{n}"})
      )

    Power.list_device_endpoints(scope, server.id).ports
  end

  defp pdu!(scope, name, feed, count \\ 2) do
    outlets =
      for n <- 1..count,
          do: %{kind: "power_outlet", name: "#{n}", attributes: %{"inlet" => "Inlet"}}

    {pdu, _expected} =
      assigned_server_fixture(scope, name, [%{kind: "power_port", name: "Inlet"} | outlets])

    %{ports: [inlet], outlets: outlets} = Power.list_device_endpoints(scope, pdu.id)
    plug!(scope, inlet, feed)
    outlets
  end

  defp plug!(scope, port, %Power.Outlet{} = outlet),
    do: {:ok, _} = Cables.connect(scope, %{power_port_id: port.id, power_outlet_id: outlet.id})

  defp plug!(scope, port, %Power.Feed{} = feed),
    do: {:ok, _} = Cables.connect(scope, %{power_port_id: port.id, power_feed_id: feed.id})

  defp redundancy(scope, ports), do: Redundancy.of(Paths.for_ports(scope, ports))

  test "ports reaching two sides, through a PDU or not, are redundant", context do
    %{scope: scope, a1: a1, b1: b1} = context
    [outlet | _] = pdu!(scope, "pdu-a", a1)
    [psu1, psu2] = ports = ports!(scope, "web-1", 2)
    plug!(scope, psu1, outlet)
    plug!(scope, psu2, b1)

    assert %Redundancy{status: :redundant, sides: ["a", "b"], unfed: [], sideless: []} =
             redundancy = redundancy(scope, ports)

    assert Enum.map(redundancy.feeds, & &1.name) == ["A1", "B1"]
  end

  test "two feeds on one side are not redundant", context do
    %{scope: scope, a1: a1, a2: a2} = context
    [psu1, psu2] = ports = ports!(scope, "web-1", 2)
    plug!(scope, psu1, a1)
    plug!(scope, psu2, a2)

    assert %Redundancy{status: :not_redundant, sides: ["a"]} = redundancy(scope, ports)
  end

  test "says which ports reach no feed and which feeds have no side", context do
    %{scope: scope, a1: a1, n1: n1} = context
    [psu1, psu2, psu3] = ports = ports!(scope, "web-1", 3)
    plug!(scope, psu1, a1)
    plug!(scope, psu2, n1)

    assert %Redundancy{status: :not_redundant, sides: ["a"]} =
             redundancy = redundancy(scope, ports)

    assert Enum.map(redundancy.unfed, & &1.id) == [psu3.id]
    assert Enum.map(redundancy.sideless, & &1.name) == ["N1"]
  end

  test "a device with one port has a single supply", %{scope: scope, a1: a1} do
    [psu1] = ports = ports!(scope, "web-1", 1)
    plug!(scope, psu1, a1)

    assert %Redundancy{status: :single_supply} = redundancy(scope, ports)
    assert %Redundancy{status: :none} = Redundancy.of([])
  end

  test "lists what loses all supply or redundancy if a feed fails", context do
    %{scope: scope, a1: a1, a2: a2, b1: b1} = context
    [a_1, a_2, a_3, a_4] = pdu!(scope, "pdu-a", a1, 4)
    [b_1, b_2] = pdu!(scope, "pdu-b", b1, 2)

    # Redundant across A1 and B1: loses redundancy.
    [psu1, psu2] = ports!(scope, "web-1", 2)
    plug!(scope, psu1, a_1)
    plug!(scope, psu2, b_1)

    # Both supplies on A1: loses everything.
    [psu1, psu2] = ports!(scope, "web-2", 2)
    plug!(scope, psu1, a_2)
    plug!(scope, psu2, a_3)

    # A1 and A2 were never redundant, and A2 keeps it running.
    [psu1, psu2] = ports!(scope, "web-3", 2)
    plug!(scope, psu1, a_4)
    plug!(scope, psu2, a2)

    # Only on B1: unaffected.
    [psu1 | _] = ports!(scope, "web-4", 2)
    plug!(scope, psu1, b_2)

    failure = Redundancy.feed_failure(scope, a1)

    assert [{%{name: "web-2"}, []}] = failure.loses_supply
    assert [{%{name: "web-1"}, [%{name: "B1"}]}] = failure.loses_redundancy
    assert {failure.keeps, failure.untraced?} == {1, false}

    assert %{
             loses_supply: [{%{name: "web-4"}, []}],
             loses_redundancy: [{%{name: "web-1"}, [%{name: "A1"}]}]
           } = Redundancy.feed_failure(scope, b1)
  end

  test "a feed with nothing below it fails nothing", %{scope: scope, n1: n1} do
    assert %{loses_supply: [], loses_redundancy: [], keeps: 0} =
             Redundancy.feed_failure(scope, n1)
  end
end
