defmodule Renga.Power.EndpointsTest do
  use Renga.DataCase, async: true

  import Renga.AccountsFixtures
  import Renga.CatalogFixtures
  import Renga.InventoryFixtures

  alias Renga.Accounts
  alias Renga.Catalog
  alias Renga.Power
  alias Renga.Power.Port

  setup do
    organization = organization_fixture()
    %{organization: organization, scope: scope_with_role(organization, "admin")}
  end

  defp scope_with_role(organization, role) do
    user = user_fixture()
    organization_membership_fixture(user, organization, %{role: role})
    Accounts.scope_for_user(user, organization.id)
  end

  @pdu_templates [
    %{
      kind: "power_port",
      name: "Inlet A",
      attributes: %{"connector" => "IEC 60309 32A", "maximum_draw_w" => 7_360}
    },
    %{kind: "power_outlet", name: "1", attributes: %{"inlet" => "Inlet A", "feed_leg" => "A"}},
    %{kind: "power_outlet", name: "2", attributes: %{"inlet" => "Inlet B", "feed_leg" => "d"}},
    %{kind: "interface", name: "mgmt0"}
  ]

  test "a device gets the ports and outlets its hardware type defines", %{scope: scope} do
    {pdu, _expected} = assigned_server_fixture(scope, "pdu-1", @pdu_templates)

    assert %{ports: [inlet], outlets: [one, two]} = Power.list_device_endpoints(scope, pdu.id)
    assert inlet.name == "Inlet A"
    assert inlet.connector == "IEC 60309 32A"
    assert inlet.maximum_draw_w == 7_360
    assert {one.name, one.inlet_port.name, one.feed_leg} == {"1", "Inlet A", "a"}
    # An unknown inlet or leg is left unset rather than guessed.
    assert {two.inlet_port, two.feed_leg} == {nil, nil}
  end

  test "an allocation override survives a template change and can be cleared", %{scope: scope} do
    {server, expected} =
      assigned_server_fixture(scope, "web-1", [
        %{kind: "power_port", name: "PSU1", attributes: %{"allocated_draw_w" => 350}},
        %{kind: "power_port", name: "PSU2", attributes: %{"allocated_draw_w" => "350"}}
      ])

    %{ports: [psu1, psu2]} = Power.list_device_endpoints(scope, server.id)
    assert Port.allocated_draw_w(psu1) == 350
    assert Port.allocated_draw_w(psu2) == 350

    assert {:ok, %Port{allocated_draw_w: 500}} =
             Power.update_port_allocation(scope, psu1, %{allocated_draw_w: "500"})

    # Suppressing PSU2 on this asset removes its port; PSU1 keeps the override.
    {:ok, _exception} =
      Catalog.put_expected_component_exception(scope, server.id, %{
        action: "suppress",
        component_template_id: expected["PSU2"].component_template_id,
        reason: "Single PSU build"
      })

    assert %{ports: [%Port{name: "PSU1", allocated_draw_w: 500} = psu1]} =
             Power.list_device_endpoints(scope, server.id)

    assert {:error, %Ecto.Changeset{}} =
             Power.update_port_allocation(scope, psu1, %{allocated_draw_w: 0})

    {:ok, cleared} = Power.update_port_allocation(scope, psu1, %{allocated_draw_w: nil})
    assert Port.allocated_draw_w(cleared) == 350
  end

  test "clearing the hardware type removes the endpoints", %{scope: scope} do
    {pdu, _expected} = assigned_server_fixture(scope, "pdu-2", @pdu_templates)
    {:ok, _} = Catalog.clear_hardware_assignment(scope, pdu.id)

    assert %{ports: [], outlets: []} = Power.list_device_endpoints(scope, pdu.id)
  end

  test "only owners and admins change allocations", %{organization: organization, scope: scope} do
    {server, _expected} =
      assigned_server_fixture(scope, "web-2", [%{kind: "power_port", name: "PSU1"}])

    %{ports: [psu1]} = Power.list_device_endpoints(scope, server.id)
    member_scope = scope_with_role(organization, "member")

    assert {:error, :forbidden} =
             Power.update_port_allocation(member_scope, psu1, %{allocated_draw_w: 100})
  end

  test "the migration backfills endpoints for assets assigned before it", %{scope: scope} do
    {pdu, _expected} = assigned_server_fixture(scope, "pdu-3", @pdu_templates)
    Repo.delete_all(Renga.Power.Outlet)
    Repo.delete_all(Port)

    [{migration, _bytecode}] =
      Code.compile_file("priv/repo/migrations/20261030173000_create_power_ports_and_outlets.exs")

    Enum.each(migration.backfill_statements(), &Repo.query!/1)

    assert %{ports: [%Port{maximum_draw_w: 7_360}], outlets: [one, two]} =
             Power.list_device_endpoints(scope, pdu.id)

    assert {one.inlet_port.name, one.feed_leg} == {"Inlet A", "a"}
    assert {two.inlet_port, two.feed_leg} == {nil, nil}
  end
end
