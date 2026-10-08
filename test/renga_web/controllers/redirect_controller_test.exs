defmodule RengaWeb.RedirectControllerTest do
  use RengaWeb.ConnCase, async: true

  @id "6f1c2b8e-4f7a-4d0e-9a52-0f3c1e8d2a41"

  # Retired URLs keep working as permanent redirects to their RFD 8 areas.
  @moved [
    {"/inventory/resources", "/inventory"},
    {"/inventory/resources/#{@id}", "/inventory/#{@id}"},
    {"/inventory/resources/#{@id}/hardware", "/inventory/#{@id}/hardware"},
    {"/inventory/component-findings", "/inbox?domain=component"},
    {"/inbox/components", "/inbox?domain=component"},
    {"/inbox/topology", "/inbox?domain=topology"},
    {"/inbox/placement", "/inbox?domain=placement"},
    {"/inventory/operations", "/settings/collectors"},
    {"/network/topology-findings", "/inbox?domain=topology"},
    {"/dcim/placement-findings", "/inbox?domain=placement"},
    {"/dcim/sites", "/places"},
    {"/dcim/sites/#{@id}", "/places/sites/#{@id}"},
    {"/dcim/locations/#{@id}", "/places/locations/#{@id}"},
    {"/dcim/racks", "/places/racks"},
    {"/dcim/racks/#{@id}", "/places/racks/#{@id}"},
    {"/dcim/manufacturers", "/catalog/manufacturers"},
    {"/dcim/hardware-types", "/catalog/hardware-types"},
    {"/dcim/hardware-types/#{@id}", "/catalog/hardware-types/#{@id}"},
    {"/dcim/module-types", "/catalog/module-types"},
    {"/dcim/module-types/#{@id}", "/catalog/module-types/#{@id}"},
    {"/ipam/vlans", "/network/vlans"},
    {"/ipam/vlan-groups", "/network/vlan-groups"}
  ]

  test "retired URLs redirect permanently to their new homes", %{conn: conn} do
    for {from, to} <- @moved do
      conn = get(conn, from)

      assert conn.status == 301, "expected #{from} to redirect permanently"
      assert redirected_to(conn, 301) == to
    end
  end

  test "carries the query string so bookmarked filters keep working", %{conn: conn} do
    conn = get(conn, "/ipam/vlans?group_id=#{@id}&q=edge")

    assert redirected_to(conn, 301) == "/network/vlans?group_id=#{@id}&q=edge"
  end

  test "joins carried filters onto a target that has its own query", %{conn: conn} do
    conn = get(conn, "/inbox/topology?interface_id=#{@id}")

    assert redirected_to(conn, 301) == "/inbox?domain=topology&interface_id=#{@id}"
  end

  test "re-encodes path parameters instead of letting them reshape the target", %{conn: conn} do
    conn = get(conn, "/dcim/racks/a%3Fb")

    assert redirected_to(conn, 301) == "/places/racks/a%3Fb"
  end

  test "area entry points redirect temporarily to their first tab", %{conn: conn} do
    for {from, to} <- [
          {"/network", "/network/topology"},
          {"/catalog", "/catalog/hardware-types"},
          {"/settings", "/settings/collectors"}
        ] do
      assert conn |> get(from) |> redirected_to(302) == to
    end
  end
end
