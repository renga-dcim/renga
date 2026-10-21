defmodule Renga.Power.CablesTest do
  use Renga.DataCase, async: true

  import Renga.AccountsFixtures
  import Renga.CatalogFixtures
  import Renga.InventoryFixtures

  alias Renga.Accounts
  alias Renga.Catalog
  alias Renga.DCIM
  alias Renga.Power
  alias Renga.Power.Cables
  alias Renga.Topology
  alias Renga.Topology.CableReconciler

  setup do
    organization = organization_fixture()
    scope = scope_with_role(organization, "admin")

    {pdu, _expected} =
      assigned_server_fixture(scope, "pdu-1", [
        %{kind: "power_port", name: "Inlet"},
        %{kind: "power_outlet", name: "1", attributes: %{"inlet" => "Inlet"}},
        %{kind: "power_outlet", name: "2", attributes: %{"inlet" => "Inlet"}}
      ])

    {server, expected} =
      assigned_server_fixture(scope, "web-1", [
        %{kind: "power_port", name: "PSU1"},
        %{kind: "power_port", name: "PSU2"}
      ])

    %{ports: [inlet], outlets: [outlet1, outlet2]} = Power.list_device_endpoints(scope, pdu.id)
    %{ports: [psu1, psu2]} = Power.list_device_endpoints(scope, server.id)

    %{
      organization: organization,
      scope: scope,
      pdu: pdu,
      server: server,
      expected: expected,
      inlet: inlet,
      outlet1: outlet1,
      outlet2: outlet2,
      psu1: psu1,
      psu2: psu2
    }
  end

  defp scope_with_role(organization, role) do
    user = user_fixture()
    organization_membership_fixture(user, organization, %{role: role})
    Accounts.scope_for_user(user, organization.id)
  end

  defp feed!(scope) do
    {:ok, site} = DCIM.create_site(scope, %{name: "DC1"}, %{slug: "dc1"})
    {:ok, panel} = Power.create_panel(scope, %{site_id: site.id, name: "PDP-1"})

    {:ok, feed} =
      Power.create_feed(scope, panel.id, %{
        name: "A1",
        supply: "ac",
        phase: "single",
        voltage: "230",
        amperage: "16"
      })

    feed
  end

  defp connections(scope) do
    scope
    |> Cables.list_cables()
    |> Enum.map(&{&1.power_port_id, &1.power_outlet_id || &1.power_feed_id})
    |> Enum.sort()
  end

  test "connecting a port to an outlet makes a current power cable", context do
    %{scope: scope, psu1: psu1, outlet1: outlet1, server: server} = context

    assert {:ok, _assertion} =
             Cables.connect(scope, %{power_port_id: psu1.id, power_outlet_id: outlet1.id})

    assert [cable] = Cables.list_cables(scope, resource_ids: [server.id])
    assert {cable.power_port.name, cable.power_outlet.name} == {"PSU1", "1"}
    assert cable.power_outlet.resource.name == "pdu-1"
    assert cable.cable_kind == "power"

    # Power cables stay out of the data cable views.
    assert Topology.list_cable_assertions(scope) == []
    assert CableReconciler.list_cables(scope.organization_id) == []

    assert {:ok, _retraction} =
             Cables.disconnect(scope, %{power_port_id: psu1.id, power_outlet_id: outlet1.id})

    assert Cables.list_cables(scope) == []
  end

  test "the newest claim wins a port and an outlet", context do
    %{scope: scope, psu1: psu1, psu2: psu2, outlet1: outlet1, outlet2: outlet2} = context

    {:ok, _} = Cables.connect(scope, %{power_port_id: psu1.id, power_outlet_id: outlet1.id})
    {:ok, _} = Cables.connect(scope, %{power_port_id: psu1.id, power_outlet_id: outlet2.id})
    assert connections(scope) == [{psu1.id, outlet2.id}]

    # PSU2 takes outlet 2. As with data cables, PSU1's older claim on outlet 1
    # was never retracted, so it holds again until someone says otherwise.
    {:ok, _} = Cables.connect(scope, %{power_port_id: psu2.id, power_outlet_id: outlet2.id})
    assert connections(scope) == Enum.sort([{psu1.id, outlet1.id}, {psu2.id, outlet2.id}])

    {:ok, _} = Cables.disconnect(scope, %{power_port_id: psu1.id, power_outlet_id: outlet1.id})
    assert connections(scope) == [{psu2.id, outlet2.id}]
  end

  test "a port can be fed straight from a panel feed", %{scope: scope, inlet: inlet} do
    feed = feed!(scope)

    assert {:ok, _} = Cables.connect(scope, %{power_port_id: inlet.id, power_feed_id: feed.id})
    assert [cable] = Cables.list_cables(scope)
    assert {cable.power_feed.name, cable.power_feed.panel.name} == {"A1", "PDP-1"}
  end

  test "a port is offered other devices' outlets and every feed", context do
    %{scope: scope, pdu: pdu, server: server, outlet1: outlet1} = context
    feed = feed!(scope)

    assert %{outlets: [], feeds: [%{id: feed_id}]} = Cables.connectable(scope, pdu.id)
    assert feed_id == feed.id
    assert %{outlets: [%{id: id} | _]} = Cables.connectable(scope, server.id)
    assert id == outlet1.id
  end

  test "rejects malformed and looping connections", context do
    %{scope: scope, inlet: inlet, psu1: psu1, outlet1: outlet1} = context
    feed = feed!(scope)

    assert {:error, :power_cable_endpoints} = Cables.connect(scope, %{power_port_id: psu1.id})

    assert {:error, :power_cable_endpoints} =
             Cables.connect(scope, %{
               power_port_id: psu1.id,
               power_outlet_id: outlet1.id,
               power_feed_id: feed.id
             })

    assert {:error, :power_cable_endpoints} =
             Cables.connect(scope, %{power_port_id: psu1.id, power_outlet_id: "not-a-uuid"})

    assert {:error, :power_loop} =
             Cables.connect(scope, %{power_port_id: inlet.id, power_outlet_id: outlet1.id})

    other_scope = scope_with_role(organization_fixture(), "admin")

    assert {:error, :power_cable_endpoints} =
             Cables.connect(other_scope, %{power_port_id: psu1.id, power_outlet_id: outlet1.id})
  end

  test "an endpoint with cable history is retired, not deleted, and can return", context do
    %{scope: scope, server: server, expected: expected, psu2: psu2, outlet1: outlet1} = context

    {:ok, _} = Cables.connect(scope, %{power_port_id: psu2.id, power_outlet_id: outlet1.id})

    {:ok, exception} =
      Catalog.put_expected_component_exception(scope, server.id, %{
        action: "suppress",
        component_template_id: expected["PSU2"].component_template_id,
        reason: "Single PSU build"
      })

    retired = Repo.get!(Renga.Power.Port, psu2.id)
    assert retired.retired_at
    # The retired port leaves the device's endpoint list.
    assert %{ports: [%{name: "PSU1"}]} = Power.list_device_endpoints(scope, server.id)

    assert {:error, :power_endpoint_retired} =
             Cables.connect(scope, %{power_port_id: psu2.id, power_outlet_id: outlet1.id})

    # Unplugging a retired port is still recorded.
    assert {:ok, _} =
             Cables.disconnect(scope, %{power_port_id: psu2.id, power_outlet_id: outlet1.id})

    {:ok, _} = Catalog.delete_expected_component_exception(scope, server.id, exception.id)
    assert Repo.get!(Renga.Power.Port, psu2.id).retired_at == nil
  end

  test "plans record intent without occupying endpoints", context do
    %{scope: scope, psu1: psu1, outlet1: outlet1} = context

    assert {:ok, plan} =
             Cables.put_plan(scope, %{
               power_port_id: psu1.id,
               power_outlet_id: outlet1.id,
               label: "web-1 A"
             })

    assert [%{label: "web-1 A"}] = Cables.list_plans(scope)
    assert Cables.list_cables(scope) == []
    assert Topology.list_cable_plans(scope) == []

    {:ok, _} =
      Cables.put_plan(scope, %{power_port_id: psu1.id, power_outlet_id: outlet1.id, label: "A"})

    assert [%{id: id, label: "A"}] = Cables.list_plans(scope)
    assert id == plan.id

    assert {:ok, _} = Cables.delete_plan(scope, plan)
    assert Cables.list_plans(scope) == []
  end

  test "only owners and admins record connections", context do
    %{organization: organization, psu1: psu1, outlet1: outlet1} = context
    member_scope = scope_with_role(organization, "member")

    assert {:error, :forbidden} =
             Cables.connect(member_scope, %{power_port_id: psu1.id, power_outlet_id: outlet1.id})
  end
end
