defmodule Renga.Power.EndpointsTest do
  use Renga.DataCase, async: true

  import Renga.AccountsFixtures
  import Renga.CatalogFixtures
  import Renga.InventoryFixtures

  alias Renga.Accounts
  alias Renga.Catalog
  alias Renga.Inventory
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

  test "assignment replacement preserves matching endpoint identities and overrides", %{
    scope: scope
  } do
    {:ok, server} =
      Inventory.create_resource(scope, %{
        kind: "server",
        name: "replacement",
        lifecycle_state: "active"
      })

    first_type =
      catalog_hardware_type_fixture(scope, "replacement-first", [
        %{kind: "power_port", name: "Inlet", attributes: %{"allocated_draw_w" => 300}},
        %{kind: "power_outlet", name: "1", attributes: %{"inlet" => "Inlet"}}
      ])

    {:ok, _assignment} = Catalog.assign_hardware_type(scope, server.id, first_type.id)

    %{ports: [first_port], outlets: [first_outlet]} =
      Power.list_device_endpoints(scope, server.id)

    {:ok, _port} = Power.update_port_allocation(scope, first_port, %{allocated_draw_w: 500})

    {:ok, _revision} =
      Catalog.create_hardware_type_revision(scope, first_type, %{}, [
        %{kind: "power_port", name: "Inlet", attributes: %{"allocated_draw_w" => 350}},
        %{kind: "power_outlet", name: "1", attributes: %{"inlet" => "Inlet"}}
      ])

    {:ok, _assignment} = Catalog.assign_hardware_type(scope, server.id, first_type.id)

    %{ports: [revised_port], outlets: [revised_outlet]} =
      Power.list_device_endpoints(scope, server.id)

    assert {revised_port.id, revised_port.default_allocated_draw_w, revised_port.allocated_draw_w} ==
             {first_port.id, 350, 500}

    assert {revised_outlet.id, revised_outlet.inlet_port_id} == {first_outlet.id, revised_port.id}

    second_type =
      catalog_hardware_type_fixture(scope, "replacement-second", [
        %{kind: "power_port", name: "Inlet", attributes: %{"allocated_draw_w" => 400}},
        %{kind: "power_outlet", name: "1", attributes: %{"inlet" => "Inlet"}}
      ])

    {:ok, _assignment} = Catalog.assign_hardware_type(scope, server.id, second_type.id)

    %{ports: [replaced_port], outlets: [replaced_outlet]} =
      Power.list_device_endpoints(scope, server.id)

    assert {replaced_port.id, replaced_port.default_allocated_draw_w,
            replaced_port.allocated_draw_w} ==
             {first_port.id, 400, 500}

    assert {replaced_outlet.id, replaced_outlet.inlet_port_id} ==
             {first_outlet.id, replaced_port.id}
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

  test "migration backfill matches runtime normalization", %{scope: scope} do
    long_connector = String.duplicate("IEC-C13-", 40)
    surrounding_whitespace = "\t\n\r\u00A0\u2003\u3000"
    oversized_watts = String.duplicate("9", 131_073)
    leading_zero_watts = String.duplicate("0", 1_000) <> "42"

    {pdu, _expected} =
      assigned_server_fixture(scope, "pdu-normalized", [
        %{
          kind: "power_port",
          name: "Inlet A",
          attributes: %{
            "connector" => surrounding_whitespace <> long_connector <> surrounding_whitespace,
            "maximum_draw_w" => surrounding_whitespace <> "+7360" <> surrounding_whitespace,
            "allocated_draw_w" => "\t350\n",
            "power_factor" => surrounding_whitespace <> "0.950" <> surrounding_whitespace
          }
        },
        %{
          kind: "power_port",
          name: "1",
          attributes: %{"connector" => 123, "allocated_draw_w" => 1.5, "power_factor" => 0.9}
        },
        %{
          kind: "power_port",
          name: "bounded",
          attributes: %{
            "connector" => surrounding_whitespace,
            "maximum_draw_w" => oversized_watts,
            "allocated_draw_w" => leading_zero_watts,
            "power_factor" => "0.9999"
          }
        },
        %{
          kind: "power_outlet",
          name: "trimmed",
          attributes: %{
            "connector" => surrounding_whitespace <> long_connector <> surrounding_whitespace,
            "inlet" => surrounding_whitespace <> "Inlet A" <> surrounding_whitespace,
            "feed_leg" => surrounding_whitespace <> "A" <> surrounding_whitespace
          }
        },
        %{
          kind: "power_outlet",
          name: "typed",
          attributes: %{"connector" => 123, "inlet" => 1, "feed_leg" => true}
        }
      ])

    runtime = normalized_endpoints(scope, pdu.id)
    assert runtime.ports["Inlet A"].connector == long_connector
    assert runtime.ports["bounded"].connector == nil
    assert runtime.ports["bounded"].maximum_draw_w == nil
    assert runtime.ports["bounded"].default_allocated_draw_w == 42
    assert Decimal.eq?(runtime.ports["Inlet A"].default_power_factor, "0.95")
    assert Decimal.eq?(runtime.ports["1"].default_power_factor, "0.9")
    assert runtime.ports["bounded"].default_power_factor == nil
    assert runtime.outlets["trimmed"].connector == long_connector

    Repo.delete_all(Renga.Power.Outlet)
    Repo.delete_all(Port)

    [{migration, _bytecode}] =
      Code.compile_file("priv/repo/migrations/20261030173000_create_power_ports_and_outlets.exs")

    Enum.each(migration.backfill_statements(), &Repo.query!/1)

    [{power_factors, _bytecode}] =
      Code.compile_file("priv/repo/migrations/20261030180000_add_power_factors.exs")

    Enum.each(power_factors.backfill_statements(), &Repo.query!/1)
    assert normalized_endpoints(scope, pdu.id) == runtime
  end

  test "power factor parsing matches the backfill at every boundary", %{scope: scope} do
    # name => {template value, what both the runtime and the backfill read}
    cases = %{
      "plain" => {"0.9", "0.9"},
      "trimmed" => {"\u00A0 0.950\t", "0.95"},
      "one" => {"1", "1"},
      "one-places" => {"1.000", "1"},
      "sixteen-places" => {"0.9990000000000000", "0.999"},
      "seventeen-places" => {"0.99900000000000000", nil},
      "sixteen-digits" => {"0000000000000001", "1"},
      "seventeen-digits" => {"00000000000000001", nil},
      "four-places" => {"0.0001", nil},
      "over-one" => {"1.0001", nil},
      "zero" => {"0", nil},
      "negative" => {"-0.5", nil},
      "exponent-text" => {"1e-1", nil},
      "plus" => {"+0.9", nil},
      "bare-point" => {".9", nil},
      "mongolian-space" => {"\u180E0.9", nil},
      "number" => {0.9, "0.9"},
      "integer" => {1, "1"},
      "trailing-zero-number" => {Renga.JSON.decode!("0.9500"), "0.95"},
      "exponent-number" => {Renga.JSON.decode!("9e-1"), "0.9"},
      "tiny-number" => {Renga.JSON.decode!("1e-7000"), nil},
      "huge-number" => {Renga.JSON.decode!("1e7000"), nil},
      "boolean" => {true, nil},
      "object" => {%{"value" => "0.9"}, nil}
    }

    templates =
      for {name, {value, _expected}} <- cases,
          do: %{kind: "power_port", name: name, attributes: %{"power_factor" => value}}

    {device, _expected} = assigned_server_fixture(scope, "pf-parity", templates)
    expected = Map.new(cases, fn {name, {_value, read}} -> {name, read && Decimal.new(read)} end)
    runtime = power_factors(scope, device.id)

    assert_same = fn read ->
      for {name, want} <- expected do
        got = Map.fetch!(read, name)
        assert (want == nil and got == nil) or (want && got && Decimal.eq?(want, got)), name
      end
    end

    assert_same.(runtime)

    Repo.update_all(Port, set: [default_power_factor: nil])

    [{power_factors, _bytecode}] =
      Code.compile_file("priv/repo/migrations/20261030180000_add_power_factors.exs")

    Enum.each(power_factors.backfill_statements(), &Repo.query!/1)
    assert_same.(power_factors(scope, device.id))
  end

  defp power_factors(scope, resource_id) do
    Map.new(
      Power.list_device_endpoints(scope, resource_id).ports,
      &{&1.name, &1.default_power_factor}
    )
  end

  defp normalized_endpoints(scope, resource_id) do
    %{ports: ports, outlets: outlets} = Power.list_device_endpoints(scope, resource_id)

    %{
      ports:
        Map.new(ports, fn port ->
          {port.name,
           %{
             connector: port.connector,
             maximum_draw_w: port.maximum_draw_w,
             default_allocated_draw_w: port.default_allocated_draw_w,
             default_power_factor: port.default_power_factor
           }}
        end),
      outlets:
        Map.new(outlets, fn outlet ->
          {outlet.name,
           %{
             connector: outlet.connector,
             feed_leg: outlet.feed_leg,
             inlet: outlet.inlet_port && outlet.inlet_port.name
           }}
        end)
    }
  end
end
