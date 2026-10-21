defmodule RengaWeb.ResourcePowerLiveTest do
  use RengaWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Renga.AccountsFixtures
  import Renga.CatalogFixtures
  import Renga.InventoryFixtures

  alias Renga.Accounts

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

  test "connects a port to another device's outlet and unplugs it", %{conn: conn, scope: scope} do
    server = server!(scope)

    {pdu, _expected} =
      assigned_server_fixture(scope, "pdu-1", [
        %{kind: "power_port", name: "Inlet"},
        %{kind: "power_outlet", name: "7", attributes: %{"inlet" => "Inlet"}}
      ])

    %{outlets: [outlet]} = Renga.Power.list_device_endpoints(scope, pdu.id)
    [psu1 | _] = Renga.Power.list_device_endpoints(scope, server.id).ports
    {:ok, view, _html} = live(conn, ~p"/inventory/#{server}/power")

    assert has_element?(view, "#power-port-#{psu1.id}", "Not recorded")
    view |> element("#connect-port-#{psu1.id}") |> render_click()
    assert has_element?(view, "#connect-form option[value='outlet:#{outlet.id}']", "Outlet 7")

    view
    |> form("#connect-form", connection: %{target: "outlet:#{outlet.id}"})
    |> render_submit()

    assert has_element?(
             view,
             "#power-port-#{psu1.id} a[href='/inventory/#{pdu.id}/power']",
             "pdu-1"
           )

    {:ok, pdu_view, _html} = live(conn, ~p"/inventory/#{pdu}/power")
    assert has_element?(pdu_view, "#power-outlet-#{outlet.id}", "web-1")

    view |> element("#unplug-port-#{psu1.id}") |> render_click()
    assert has_element?(view, "#power-port-#{psu1.id}", "Not recorded")
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
