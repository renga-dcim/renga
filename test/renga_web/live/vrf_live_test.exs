defmodule RengaWeb.VrfLiveTest do
  @moduledoc """
  Network → VRFs (RFD 4, Phase 2): every routing table with its prefix
  count, and owner/admin create, edit, and delete of VRFs.
  """
  use RengaWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Renga.AccountsFixtures
  import Renga.InventoryFixtures
  import Renga.TopologyFixtures

  alias Renga.Accounts
  alias Renga.IPAM
  alias Renga.IPAM.Vrf
  alias Renga.Repo

  setup do
    organization = organization_fixture()
    {admin_conn, admin} = sign_in(organization, "admin")
    {member_conn, _member} = sign_in(organization, "member")
    %{admin_conn: admin_conn, admin: admin, member_conn: member_conn}
  end

  test "lists the global table and each VRF with its prefixes", context do
    blue = vrf_fixture(context.admin, "blue", %{route_distinguisher: "65000:1"})
    empty = vrf_fixture(context.admin, "empty")
    prefix_fixture(context.admin, "10.0.0.0/24")
    prefix_fixture(context.admin, "10.0.0.0/24", %{vrf: "blue"})
    prefix_fixture(context.admin, "10.0.1.0/24", %{vrf: "blue"})

    other = sign_in(organization_fixture(), "admin") |> elem(1)
    foreign = vrf_fixture(other, "foreign")

    {:ok, view, _html} = live(context.member_conn, ~p"/network/vrfs")

    assert has_element?(view, "#area-tabs a[aria-current=page]", "VRFs")
    assert has_element?(view, "#vrf-global", "Global")

    assert has_element?(
             view,
             "#vrf-global-prefixes[href='/network/prefixes']",
             "1 prefix"
           )

    assert has_element?(view, "#vrf-#{blue.id}", "65000:1")

    assert has_element?(
             view,
             "#vrf-#{blue.id}-prefixes[href='/network/prefixes?vrf=blue']",
             "2 prefixes"
           )

    assert has_element?(view, "#vrf-#{empty.id}-prefixes", "0 prefixes")
    refute has_element?(view, "#vrf-#{foreign.id}")
    refute has_element?(view, "#vrfs-empty")
  end

  test "an admin creates a VRF and sees the form's errors", context do
    vrf_fixture(context.admin, "blue")
    {:ok, view, _html} = live(context.admin_conn, ~p"/network/vrfs")
    view |> element("#new-vrf") |> render_click()

    view |> form("#vrf-form", vrf: %{name: "BLUE"}) |> render_submit()
    assert has_element?(view, "#vrf-form", "is already a VRF in this organization")

    view |> form("#vrf-form", vrf: %{name: "default"}) |> render_change()
    assert has_element?(view, "#vrf-form", "is reserved for the global routing table")

    view
    |> form("#vrf-form", vrf: %{name: "Tenant", route_distinguisher: "65000:7"})
    |> render_submit()

    assert has_element?(view, "#flash-info", "VRF Tenant created")
    vrf = Repo.get_by!(Vrf, name: "Tenant")
    assert vrf.route_distinguisher == "65000:7"
    assert has_element?(view, "#vrf-#{vrf.id}", "Tenant")
  end

  test "an admin renames a VRF, and a stale form cannot overwrite a newer edit", context do
    vrf = vrf_fixture(context.admin, "blue")
    prefix = prefix_fixture(context.admin, "10.0.0.0/24", %{vrf: "blue"})
    {:ok, view, _html} = live(context.admin_conn, ~p"/network/vrfs")

    view |> element("#vrf-#{vrf.id}-edit") |> render_click()
    assert has_element?(view, "#vrf-panel", "Edit blue")

    view |> form("#vrf-form", vrf: %{name: "Tenant", status: "deprecated"}) |> render_submit()

    assert has_element?(view, "#flash-info", "VRF Tenant saved")
    assert has_element?(view, "#vrf-#{vrf.id}-status", "Deprecated")
    assert Repo.get!(Renga.Inventory.Resource, prefix.resource_id).display_name =~ "(Tenant)"

    view |> element("#vrf-#{vrf.id}-edit") |> render_click()

    {:ok, _} =
      IPAM.update_vrf(context.admin, IPAM.get_vrf!(context.admin, vrf.id), %{name: "Elsewhere"})

    view |> form("#vrf-form", vrf: %{name: "Mine"}) |> render_submit()
    assert has_element?(view, "#vrf-edit-conflict", "This VRF changed elsewhere")
    assert Repo.get!(Vrf, vrf.id).name == "Elsewhere"
  end

  test "an admin deletes an empty VRF but not one holding prefixes", context do
    empty = vrf_fixture(context.admin, "empty")
    busy = vrf_fixture(context.admin, "busy")
    prefix_fixture(context.admin, "10.0.0.0/24", %{vrf: "busy"})
    {:ok, view, _html} = live(context.admin_conn, ~p"/network/vrfs")

    assert has_element?(view, "#vrf-#{busy.id}-delete[disabled]")
    refute has_element?(view, "#delete-vrf-#{busy.id}")

    render_hook(view, "delete", %{"id" => busy.id})
    assert has_element?(view, "#flash-error", "Move or delete the VRF's prefixes")
    assert Repo.get(Vrf, busy.id)

    assert has_element?(view, "#delete-vrf-#{empty.id}", "Delete empty?")
    view |> element("#delete-vrf-#{empty.id}-confirm") |> render_click()

    assert has_element?(view, "#flash-info", "VRF empty deleted")
    refute has_element?(view, "#vrf-#{empty.id}")
    refute Repo.get(Vrf, empty.id)
  end

  test "VRFs added elsewhere appear without a reload", context do
    {:ok, view, _html} = live(context.member_conn, ~p"/network/vrfs")
    assert has_element?(view, "#vrfs-empty")

    vrf = vrf_fixture(context.admin, "blue")
    send(view.pid, :reload)

    assert has_element?(view, "#vrf-#{vrf.id}", "blue")
    refute has_element?(view, "#vrfs-empty")
  end

  test "members see no controls and cannot write VRFs", context do
    vrf = vrf_fixture(context.admin, "blue")
    {:ok, view, _html} = live(context.member_conn, ~p"/network/vrfs")

    refute has_element?(view, "#new-vrf")
    refute has_element?(view, "#vrf-form")
    refute has_element?(view, "#vrf-#{vrf.id}-edit")
    refute has_element?(view, "#vrf-#{vrf.id}-delete")

    render_hook(view, "save", %{"vrf" => %{"name" => "red"}})
    assert has_element?(view, "#flash-error", "Only owners and admins manage VRFs")

    render_hook(view, "delete", %{"id" => vrf.id})
    assert Repo.get(Vrf, vrf.id)
    assert [%{name: "blue"}] = IPAM.list_vrfs(context.admin)
  end

  test "requires authentication" do
    assert {:error, {:redirect, %{to: path}}} = live(build_conn(), ~p"/network/vrfs")
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
