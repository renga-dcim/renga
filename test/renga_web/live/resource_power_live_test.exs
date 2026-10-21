defmodule RengaWeb.ResourcePowerLiveTest do
  use RengaWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Renga.AccountsFixtures
  import Renga.CatalogFixtures
  import Renga.InventoryFixtures

  alias Renga.Accounts
  alias Renga.Catalog
  alias Renga.Power
  alias Renga.Power.Cables
  alias Renga.Power.Port
  alias Renga.Repo
  alias Renga.Topology.CableAssertion

  setup %{conn: conn} do
    organization = organization_fixture()
    {conn, scope} = sign_in(conn, organization, "admin")
    %{conn: conn, scope: scope, organization: organization}
  end

  defp sign_in(conn, organization, role) do
    user = user_fixture()
    organization_membership_fixture(user, organization, %{role: role})

    conn =
      conn
      |> log_in_user(user)
      |> put_session(:current_organization_id, organization.id)

    {conn, Accounts.scope_for_user(user, organization.id)}
  end

  defp server!(scope) do
    {server, _expected} =
      assigned_server_fixture(scope, "web-1", [
        %{
          kind: "power_port",
          name: "PSU1",
          attributes: %{"maximum_draw_w" => 800, "allocated_draw_w" => 350}
        },
        %{kind: "power_port", name: "PSU2", attributes: %{"maximum_draw_w" => 800}}
      ])

    server
  end

  test "lists ports with their draws and overrides an allocation", %{conn: conn, scope: scope} do
    server = server!(scope)
    {:ok, view, _html} = live(conn, ~p"/inventory/#{server}/power")

    assert has_element?(view, "#resource-detail a[href='/inventory/#{server.id}/power']", "Power")
    assert has_element?(view, "#power-ports tr", "PSU1")
    assert has_element?(view, "#power-allocated-total", "Allocation unknown for 1 of 2 ports")

    [psu2] =
      for port <- Renga.Power.list_device_endpoints(scope, server.id).ports,
          port.name == "PSU2",
          do: port

    render_click(view, "edit_port", %{"id" => psu2.id})

    view
    |> form("#allocation-form", allocation: %{allocated_draw_w: "400"})
    |> render_submit()

    assert has_element?(view, "#power-port-#{psu2.id}", "set here")
    assert has_element?(view, "#power-allocated-total", "750")
  end

  test "shows each port's power factor and where it comes from", %{conn: conn, scope: scope} do
    {server, _expected} =
      assigned_server_fixture(scope, "web-pf", [
        %{kind: "power_port", name: "PSU1", attributes: %{"power_factor" => "0.95"}},
        %{kind: "power_port", name: "PSU2"}
      ])

    %{ports: [psu1, psu2]} = Power.list_device_endpoints(scope, server.id)
    {:ok, view, _html} = live(conn, ~p"/inventory/#{server}/power")

    assert has_element?(view, "#power-factor-#{psu1.id}", "0.950 from hardware type")
    assert has_element?(view, "#power-factor-#{psu2.id}", "Not set")

    render_click(view, "edit_port", %{"id" => psu2.id})
    assert has_element?(view, "#power-factor-fallback", "Leave empty to leave it unknown")

    view
    |> form("#allocation-form", allocation: %{allocated_draw_w: "", power_factor: "0.9"})
    |> render_submit()

    assert has_element?(view, "#power-factor-#{psu2.id}", "0.900 set here")

    render_click(view, "edit_port", %{"id" => psu1.id})

    assert view
           |> form("#allocation-form", allocation: %{power_factor: "1.5"})
           |> render_submit() =~ "must be less than or equal to 1"
  end

  test "a port without its own power factor shows the organization default", %{
    conn: conn,
    organization: organization,
    scope: scope
  } do
    server = server!(scope)
    {_owner_conn, owner} = sign_in(conn, organization, "owner")
    {:ok, _organization} = Power.set_default_power_factor(owner, "0.9")
    %{ports: [psu1, _psu2]} = Power.list_device_endpoints(scope, server.id)

    {:ok, view, _html} = live(conn, ~p"/inventory/#{server}/power")
    assert has_element?(view, "#power-factor-#{psu1.id}", "0.900 organization default")
  end

  test "connects a port to another device's outlet and unplugs it", %{conn: conn, scope: scope} do
    server = server!(scope)

    {pdu, _expected} =
      assigned_server_fixture(scope, "pdu-1", [
        %{kind: "power_port", name: "Inlet"},
        %{kind: "power_outlet", name: "7", attributes: %{"inlet" => "Inlet"}}
      ])

    %{outlets: [outlet]} = Power.list_device_endpoints(scope, pdu.id)
    [psu1 | _] = Power.list_device_endpoints(scope, server.id).ports
    {:ok, view, _html} = live(conn, ~p"/inventory/#{server}/power")

    assert has_element?(view, "#power-port-#{psu1.id}", "Not recorded")
    view |> element("#connect-port-#{psu1.id}") |> render_click()
    assert has_element?(view, "#connect-form option[value='outlet:#{outlet.id}']", "Outlet 7")

    view
    |> form("#connect-form", connection: %{target: ""})
    |> render_submit()

    assert has_element?(
             view,
             "#connect-error[role='alert']",
             "Choose an outlet or feed to connect"
           )

    refute has_element?(view, "#flash-error")

    view
    |> form("#connect-form", connection: %{target: "outlet:#{outlet.id}"})
    |> render_submit()

    # The PDU's own inlet has no feed yet, so the path says where it stops.
    assert has_element?(view, "#power-port-#{psu1.id}", "Inlet not connected")
    view |> element("#power-path-#{psu1.id}") |> render_click()
    assert has_element?(view, "#path-panel-title", "Power path for PSU1")
    assert has_element?(view, "#power-path-detail", "pdu-1")
    assert has_element?(view, "#power-path-detail", "Outlet 7 via inlet Inlet")
    assert has_element?(view, "#power-path-terminal", "Path stops here")

    {:ok, pdu_view, _html} = live(conn, ~p"/inventory/#{pdu}/power")
    assert has_element?(pdu_view, "#power-outlet-#{outlet.id}", "web-1")

    view |> element("#unplug-port-#{psu1.id}") |> render_click()
    assert has_element?(view, "#power-port-#{psu1.id}", "Not recorded")
  end

  test "a stale unplug event leaves the replacement connection in place", %{
    conn: conn,
    scope: scope
  } do
    server = server!(scope)

    {pdu, _expected} =
      assigned_server_fixture(scope, "pdu-1", [
        %{kind: "power_port", name: "Inlet"},
        %{kind: "power_outlet", name: "1", attributes: %{"inlet" => "Inlet"}},
        %{kind: "power_outlet", name: "2", attributes: %{"inlet" => "Inlet"}}
      ])

    %{outlets: [outlet1, outlet2]} = Power.list_device_endpoints(scope, pdu.id)
    [psu1 | _] = Power.list_device_endpoints(scope, server.id).ports
    {:ok, _} = Cables.connect(scope, %{power_port_id: psu1.id, power_outlet_id: outlet1.id})
    [old_cable] = Cables.list_cables(scope)
    {:ok, view, _html} = live(conn, ~p"/inventory/#{server}/power")

    {:ok, _} = Cables.connect(scope, %{power_port_id: psu1.id, power_outlet_id: outlet2.id})
    render_click(view, "unplug_port", %{"id" => old_cable.id})

    assert has_element?(view, "#flash-error", "That connection has already changed")
    view |> element("#power-path-#{psu1.id}") |> render_click()
    assert has_element?(view, "#power-path-detail", "pdu-1")
    assert has_element?(view, "#power-path-detail", "Outlet 2 via inlet Inlet")

    assert [{psu1.id, outlet2.id}] ==
             Enum.map(Cables.list_cables(scope), &{&1.power_port_id, &1.power_outlet_id})
  end

  test "a retained connection can be unplugged after its port is retired", %{
    conn: conn,
    scope: scope
  } do
    {server, expected} =
      assigned_server_fixture(scope, "web-1", [
        %{kind: "power_port", name: "PSU1"}
      ])

    {pdu, _expected} =
      assigned_server_fixture(scope, "pdu-1", [
        %{kind: "power_port", name: "Inlet"},
        %{kind: "power_outlet", name: "7", attributes: %{"inlet" => "Inlet"}}
      ])

    %{ports: [port]} = Power.list_device_endpoints(scope, server.id)
    %{outlets: [outlet]} = Power.list_device_endpoints(scope, pdu.id)
    {:ok, _} = Cables.connect(scope, %{power_port_id: port.id, power_outlet_id: outlet.id})

    {:ok, _exception} =
      Catalog.put_expected_component_exception(scope, server.id, %{
        action: "suppress",
        component_template_id: expected["PSU1"].component_template_id,
        reason: "Single PSU build"
      })

    [cable] = Cables.list_cables(scope)
    {:ok, view, _html} = live(conn, ~p"/inventory/#{server}/power")

    assert has_element?(view, "#retired-power-connections", "Port PSU1")
    view |> element("#unplug-retired-cable-#{cable.id}") |> render_click()

    assert Cables.list_cables(scope) == []
    assert Repo.get!(Port, port.id).retired_at
    assert Repo.aggregate(CableAssertion, :count, :id) == 2
    refute has_element?(view, "#retired-power-connections")
  end

  test "members read but cannot edit", %{conn: conn, scope: scope, organization: organization} do
    server = server!(scope)
    {member_conn, _scope} = sign_in(conn, organization, "member")
    {:ok, view, _html} = live(member_conn, ~p"/inventory/#{server}/power")

    assert has_element?(view, "#power-ports tr", "PSU2")
    refute has_element?(view, "#allocation-form")
    refute has_element?(view, "#connect-form")
  end
end
