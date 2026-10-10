defmodule RengaWeb.AddressLiveTest do
  @moduledoc """
  Network → Addresses (RFD 4, Phase 3): search managed addresses across
  routing tables, reserve them, edit their intent, manage assignments, and
  release them, owners and admins only.
  """
  use RengaWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Renga.AccountsFixtures
  import Renga.InventoryFixtures
  import Renga.TopologyFixtures

  alias Renga.Accounts
  alias Renga.IPAM
  alias Renga.IPAM.IpAddress
  alias Renga.Repo

  setup do
    organization = organization_fixture()
    {admin_conn, admin} = sign_in(organization, "admin")
    {member_conn, _member} = sign_in(organization, "member")
    {web, web_ports} = device_fixture(admin, "server", "web-01", ~w(eth0 eth1))
    {_lb, lb_ports} = device_fixture(admin, "server", "lb-02", ~w(eth0))

    %{
      admin_conn: admin_conn,
      admin: admin,
      member_conn: member_conn,
      web: web,
      web_eth0: web_ports["eth0"],
      lb_eth0: lb_ports["eth0"]
    }
  end

  test "searches managed addresses by address, text, and routing table", context do
    observed = address_fixture(context.admin, context.web_eth0, "192.0.2.5/24")
    {:ok, adopted} = IPAM.adopt_address(context.admin, observed.id)

    {:ok, reserved} =
      IPAM.create_ip_address(context.admin, %{
        address: "198.51.100.7/24",
        dns_name: "gw.example.net"
      })

    blue = vrf_fixture(context.admin, "blue")

    {:ok, in_blue} =
      IPAM.create_ip_address(context.admin, %{address: "192.0.2.5/24", vrf_id: blue.id})

    {:ok, released} = IPAM.create_ip_address(context.admin, %{address: "203.0.113.9"})
    {:ok, _} = IPAM.release_address(context.admin, released.id)

    {:ok, view, _html} = live(context.member_conn, ~p"/network/addresses")

    assert has_element?(view, "#area-tabs a[aria-current=page]", "Addresses")
    assert has_element?(view, "#address-#{adopted.id}", "192.0.2.5/24")
    assert has_element?(view, "#address-#{adopted.id}", "eth0")
    assert has_element?(view, "#address-#{adopted.id}-state", "Allocated")
    assert has_element?(view, "#address-#{reserved.id}-state", "Reserved")
    assert has_element?(view, "#address-#{in_blue.id}", "blue")
    refute has_element?(view, "#address-#{released.id}")

    # A CIDR finds the hosts inside it, in every table.
    view |> form("#address-filter", filter: %{q: "192.0.2.0/24"}) |> render_change()
    assert_patch(view, ~p"/network/addresses?q=192.0.2.0%2F24")
    assert has_element?(view, "#address-#{adopted.id}")
    assert has_element?(view, "#address-#{in_blue.id}")
    refute has_element?(view, "#address-#{reserved.id}")

    # Text matches DNS names and assigned devices.
    {:ok, view, _html} = live(context.member_conn, ~p"/network/addresses?q=web-01")
    assert has_element?(view, "#address-#{adopted.id}")
    refute has_element?(view, "#address-#{reserved.id}")

    {:ok, view, _html} = live(context.member_conn, ~p"/network/addresses?q=gw.example")
    assert has_element?(view, "#address-#{reserved.id}")

    {:ok, view, _html} = live(context.member_conn, ~p"/network/addresses?vrf=BLUE")
    assert has_element?(view, "#address-#{in_blue.id}")
    refute has_element?(view, "#address-#{adopted.id}")

    {:ok, view, _html} = live(context.member_conn, ~p"/network/addresses?vrf=global")
    refute has_element?(view, "#address-#{in_blue.id}")

    {:ok, view, _html} = live(context.member_conn, ~p"/network/addresses?released=true")
    assert has_element?(view, "#address-#{released.id}-state", "Released")
    refute has_element?(view, "#address-#{released.id}-edit")

    {:ok, view, _html} = live(context.member_conn, ~p"/network/addresses?q=nothing-here")
    assert has_element?(view, "#address-list-empty", "No managed address matches")
  end

  test "the Global table and a VRF named global have distinct filters", context do
    table = vrf_fixture(context.admin, "global")
    {:ok, global} = IPAM.create_ip_address(context.admin, %{address: "192.0.2.10"})

    {:ok, in_vrf} =
      IPAM.create_ip_address(context.admin, %{address: "192.0.2.10", vrf_id: table.id})

    {:ok, view, _} = live(context.member_conn, ~p"/network/addresses")
    view |> form("#address-filter", filter: %{vrf: "id:" <> table.id}) |> render_change()
    assert_patch(view, ~p"/network/addresses?#{[vrf: "id:" <> table.id]}")
    assert has_element?(view, "#address-#{in_vrf.id}")
    refute has_element?(view, "#address-#{global.id}")

    view |> form("#address-filter", filter: %{vrf: "global"}) |> render_change()
    assert_patch(view, ~p"/network/addresses?vrf=global")
    assert has_element?(view, "#address-#{global.id}")
    refute has_element?(view, "#address-#{in_vrf.id}")
  end

  test "an admin reserves an address and sees the form's errors", context do
    {:ok, _} = IPAM.create_ip_address(context.admin, %{address: "192.0.2.10/24"})
    {:ok, view, _html} = live(context.admin_conn, ~p"/network/addresses")

    view |> element("#new-address") |> render_click()
    assert has_element?(view, "#address-panel", "Reserve address")

    view |> form("#address-form", ip_address: %{address: "not an address"}) |> render_change()
    assert has_element?(view, "#address-form", "is invalid")

    view |> form("#address-form", ip_address: %{address: "192.0.2.10/32"}) |> render_submit()
    assert has_element?(view, "#address-form", "is already managed in this routing table")

    view
    |> form("#address-form",
      ip_address: %{address: "192.0.2.11/24", role: "vip", dns_name: "vip.example.net"}
    )
    |> render_submit()

    assert has_element?(view, "#flash-info", "192.0.2.11 reserved")
    reserved = Repo.get_by!(IpAddress, dns_name: "vip.example.net")
    assert %{allocation_state: "reserved", role: "vip"} = reserved
    assert has_element?(view, "#address-#{reserved.id}", "VIP")
    refute has_element?(view, "#address-panel")
  end

  test "an admin shares a VIP across interfaces and removes one assignment", context do
    {:ok, address} = IPAM.create_ip_address(context.admin, %{address: "192.0.2.20/24"})
    {:ok, view, _html} = live(context.admin_conn, ~p"/network/addresses")

    view |> element("#address-#{address.id}-edit") |> render_click()
    assert has_element?(view, "#address-unassigned")

    view |> form("#assign-form", assign: %{interface: "web-01"}) |> render_change()
    assert has_element?(view, "#assign-#{context.web_eth0.id}", "eth0")
    view |> element("#assign-#{context.web_eth0.id}") |> render_click()

    # An ordinary address takes one interface.
    view |> form("#assign-form", assign: %{interface: "lb-02"}) |> render_change()
    view |> element("#assign-#{context.lb_eth0.id}") |> render_click()
    assert has_element?(view, "#assign-error", "only a VIP, anycast, or first-hop")

    view |> form("#address-form", ip_address: %{role: "vip"}) |> render_submit()
    assert has_element?(view, "#flash-info", "192.0.2.20 saved")

    view |> element("#address-#{address.id}-edit") |> render_click()
    view |> form("#assign-form", assign: %{interface: "lb-02"}) |> render_change()
    view |> element("#assign-#{context.lb_eth0.id}") |> render_click()

    shared = IPAM.get_ip_address!(context.admin, address.id)
    assert length(shared.assignments) == 2
    assert has_element?(view, "#address-#{address.id}", "lb-02")

    [first | _] = shared.assignments
    view |> element("#assignment-#{first.id}-remove") |> render_click()
    refute has_element?(view, "#assignment-#{first.id}")
    assert length(IPAM.get_ip_address!(context.admin, address.id).assignments) == 1
  end

  test "unassignment is scoped to the open edit and refreshes concurrent removals", context do
    observed_a = address_fixture(context.admin, context.web_eth0, "192.0.2.21")
    observed_b = address_fixture(context.admin, context.lb_eth0, "192.0.2.22")
    {:ok, a} = IPAM.adopt_address(context.admin, observed_a.id)
    {:ok, b} = IPAM.adopt_address(context.admin, observed_b.id)
    [assignment_a] = a.assignments
    [assignment_b] = b.assignments
    {:ok, view, _} = live(context.admin_conn, ~p"/network/addresses")

    render_hook(view, "unassign", %{"id" => assignment_b.id})
    assert [_] = IPAM.get_ip_address!(context.admin, b.id).assignments
    view |> element("#address-#{a.id}-edit") |> render_click()
    view |> form("#address-form", ip_address: %{description: "My draft"}) |> render_change()

    render_hook(view, "unassign", %{"id" => assignment_b.id})
    assert [_] = IPAM.get_ip_address!(context.admin, b.id).assignments
    assert has_element?(view, "#assignment-#{assignment_a.id}")
    refute has_element?(view, "#assignment-#{assignment_b.id}")

    {:ok, _} = IPAM.unassign_address(context.admin, assignment_a.id)
    view |> element("#assignment-#{assignment_a.id}-remove") |> render_click()
    assert has_element?(view, "#address-unassigned")
    assert has_element?(view, "#assign-error", "already removed")

    assert has_element?(
             view,
             "#address-form input[name='ip_address[description]'][value='My draft']"
           )
  end

  test "a stale edit stays open with the conflict instead of overwriting", context do
    {:ok, address} = IPAM.create_ip_address(context.admin, %{address: "192.0.2.30/24"})
    {:ok, view, _html} = live(context.admin_conn, ~p"/network/addresses")

    view |> element("#address-#{address.id}-edit") |> render_click()
    {:ok, _} = IPAM.update_ip_address(context.admin, address, %{description: "Elsewhere"})

    view |> form("#address-form", ip_address: %{description: "Mine"}) |> render_submit()
    assert has_element?(view, "#address-edit-conflict", "changed elsewhere")
    assert Repo.get!(IpAddress, address.id).description == "Elsewhere"
  end

  test "an admin releases an address from its confirmation", context do
    observed = address_fixture(context.admin, context.web_eth0, "192.0.2.40/24")
    {:ok, adopted} = IPAM.adopt_address(context.admin, observed.id)
    {:ok, view, _html} = live(context.admin_conn, ~p"/network/addresses")

    assert has_element?(view, "#release-address-#{adopted.id}", "Its assignment ends.")
    view |> element("#release-address-#{adopted.id}-confirm") |> render_click()

    assert has_element?(view, "#flash-info", "192.0.2.40 released")
    refute has_element?(view, "#address-#{adopted.id}")

    assert Repo.get!(Renga.Inventory.Resource, adopted.resource_id).lifecycle_state ==
             "retired"
  end

  test "members read but cannot change addresses", context do
    {:ok, address} = IPAM.create_ip_address(context.admin, %{address: "192.0.2.50"})
    {:ok, view, _html} = live(context.member_conn, ~p"/network/addresses")

    refute has_element?(view, "#new-address")
    refute has_element?(view, "#address-#{address.id}-edit")
    refute has_element?(view, "#release-address-#{address.id}")

    render_hook(view, "save", %{"ip_address" => %{"address" => "192.0.2.51"}})
    assert has_element?(view, "#flash-error", "Only owners and admins manage addresses")

    render_hook(view, "release", %{"id" => address.id})
    assert Repo.get!(Renga.Inventory.Resource, address.resource_id).lifecycle_state == "active"
  end

  test "another organization's addresses stay out of the list", context do
    other = sign_in(organization_fixture(), "admin") |> elem(1)
    {:ok, foreign} = IPAM.create_ip_address(other, %{address: "192.0.2.60"})

    {:ok, view, _html} = live(context.admin_conn, ~p"/network/addresses")
    refute has_element?(view, "#address-#{foreign.id}")
    render_hook(view, "edit", %{"id" => foreign.id})
    assert has_element?(view, "#flash-error", "That address is gone")
  end

  test "requires authentication" do
    assert {:error, {:redirect, %{to: path}}} = live(build_conn(), ~p"/network/addresses")
    assert path =~ "/users/log-in"
  end

  defp sign_in(organization, role) do
    user = user_fixture()
    organization_membership_fixture(user, organization, %{role: role})

    conn =
      build_conn()
      |> log_in_user(user)
      |> put_session(:current_organization_id, organization.id)

    {conn, Accounts.scope_for_user(user, organization.id)}
  end
end
