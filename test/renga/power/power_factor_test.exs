defmodule Renga.Power.PowerFactorTest do
  use Renga.DataCase, async: true

  import Renga.AccountsFixtures
  import Renga.CatalogFixtures
  import Renga.InventoryFixtures

  alias Renga.Accounts
  alias Renga.Inventory
  alias Renga.Power
  alias Renga.Power.Port
  alias Renga.Power.PowerFactor

  setup do
    organization = organization_fixture()
    %{organization: organization, scope: scope_with_role(organization, "owner")}
  end

  defp scope_with_role(organization, role) do
    user = user_fixture()
    organization_membership_fixture(user, organization, %{role: role})
    Accounts.scope_for_user(user, organization.id)
  end

  defp ports!(scope, templates) do
    {server, _expected} = assigned_server_fixture(scope, "web-1", templates)
    Power.list_device_endpoints(scope, server.id).ports
  end

  test "a port's override wins, then its template, then the organization default", %{
    scope: scope
  } do
    [psu1, psu2] =
      ports!(scope, [
        %{kind: "power_port", name: "PSU1", attributes: %{"power_factor" => 0.95}},
        %{kind: "power_port", name: "PSU2"}
      ])

    default = Decimal.new("0.9")
    assert %PowerFactor{source: :hardware_type} = pf = PowerFactor.for_port(psu1, default)
    assert Decimal.eq?(pf.value, "0.95")
    assert %PowerFactor{source: :organization_default} = PowerFactor.for_port(psu2, default)
    # With no default, nothing is assumed.
    assert PowerFactor.for_port(psu2, nil) == nil

    {:ok, psu1} = Power.update_port_allocation(scope, psu1, %{power_factor: "0.99"})
    assert %PowerFactor{source: :port} = pf = PowerFactor.for_port(psu1, default)
    assert Decimal.eq?(pf.value, "0.99")

    {:ok, psu1} = Power.update_port_allocation(scope, psu1, %{power_factor: nil})
    assert %PowerFactor{source: :hardware_type} = PowerFactor.for_port(psu1, default)
  end

  test "converts watts to volt-amperes" do
    pf = %PowerFactor{value: Decimal.new("0.8"), source: :port}
    assert Decimal.eq?(PowerFactor.to_va(400, pf), 500)
  end

  test "an override is recorded on the device's activity", %{scope: scope} do
    [psu1] = ports!(scope, [%{kind: "power_port", name: "PSU1"}])
    {:ok, _port} = Power.update_port_allocation(scope, psu1, %{power_factor: "0.9"})

    assert [%{field: "power_factor", new_value: %{"port" => "PSU1", "value" => "0.9"}}] =
             scope
             |> Inventory.list_change_events(psu1.resource_id)
             |> Enum.filter(&(&1.field == "power_factor"))
  end

  test "rejects a power factor outside (0, 1] or finer than three places", %{scope: scope} do
    [psu1] = ports!(scope, [%{kind: "power_port", name: "PSU1"}])

    # Far out of range values are rejected, not raised on while rounding.
    for value <- ["0", "1.01", "-0.5", "0.9999", "1e32", "-1e32", "NaN"] do
      assert {:error, %Ecto.Changeset{errors: [power_factor: _]}} =
               Power.update_port_allocation(scope, psu1, %{power_factor: value}),
             "expected #{value} to be rejected"
    end

    assert {:ok, %Port{}} = Power.update_port_allocation(scope, psu1, %{power_factor: "1"})
  end

  test "parses template attributes strictly" do
    assert Decimal.eq?(PowerFactor.parse(0.95), "0.95")
    assert Decimal.eq?(PowerFactor.parse(1), 1)
    assert Decimal.eq?(PowerFactor.parse(Decimal.new("0.95")), "0.95")
    assert Decimal.eq?(PowerFactor.parse(" 0.900 "), "0.9")

    for value <- [0, 1.5, "0.9999", "1e-1", "+0.9", ".9", "0.9x", true, nil, %{}] do
      assert PowerFactor.parse(value) == nil, "expected #{inspect(value)} to be ignored"
    end
  end

  test "only an owner sets the organization default", %{
    organization: organization,
    scope: scope
  } do
    assert Power.default_power_factor(scope) == nil

    for role <- ~w(admin member) do
      assert {:error, :forbidden} =
               organization
               |> scope_with_role(role)
               |> Power.set_default_power_factor("0.9")
    end

    assert {:ok, _organization} = Power.set_default_power_factor(scope, "0.9")
    assert Decimal.eq?(Power.default_power_factor(scope), "0.9")

    for value <- ["1.2", "1e32"] do
      assert {:error, %Ecto.Changeset{}} = Power.set_default_power_factor(scope, value)
    end

    assert {:ok, _organization} = Power.set_default_power_factor(scope, nil)
    assert Power.default_power_factor(scope) == nil
    # Clearing an unset default changes nothing and records nothing.
    assert {:ok, _organization} = Power.set_default_power_factor(scope, nil)

    changes =
      for event <- Inventory.list_activity(scope),
          event.field == "default_power_factor",
          do: {event.old_value, event.new_value}

    assert Enum.sort(changes) ==
             Enum.sort([{nil, %{"value" => "0.9"}}, {%{"value" => "0.9"}, nil}])
  end

  test "RFD 17 permissions: organization.manage sets the default, dcim.edit the port, topology.edit the cable",
       %{organization: organization, scope: owner} do
    [psu1] = ports!(owner, [%{kind: "power_port", name: "PSU1"}])
    {:ok, site} = Renga.DCIM.create_site(owner, %{name: "DC1"}, %{slug: "dc1"})
    {:ok, panel} = Power.create_panel(owner, %{site_id: site.id, name: "PDP-1"})

    {:ok, feed} =
      Power.create_feed(owner, panel.id, %{name: "A1", voltage: "230", amperage: "16"})

    {:ok, role} =
      Renga.Roles.create_role(owner, %{
        "name" => "Facilities",
        "permissions" => ["dcim.edit", "organization.manage"]
      })

    facilities = scope_with_role(organization, "viewer")

    {:ok, _assignment} =
      Renga.Assignments.assign(owner, facilities.membership_id, %{"role" => role.id})

    facilities = Accounts.scope_for_user(facilities.user, organization.id)

    assert {:ok, _organization} = Power.set_default_power_factor(facilities, "0.95")
    assert {:ok, %Port{}} = Power.update_port_allocation(facilities, psu1, %{power_factor: "0.9"})

    assert {:error, :forbidden} =
             Renga.Power.Cables.connect(facilities, %{
               power_port_id: psu1.id,
               power_feed_id: feed.id
             })

    # An admin holds dcim.edit but not the owner-only organization.manage.
    admin = scope_with_role(organization, "admin")
    assert {:error, :forbidden} = Power.set_default_power_factor(admin, "0.8")
    assert {:ok, %Port{}} = Power.update_port_allocation(admin, psu1, %{power_factor: nil})
  end
end
