defmodule RengaWeb.DcimLiveTest do
  use RengaWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Renga.AccountsFixtures
  import Renga.InventoryFixtures

  alias Renga.Accounts
  alias Renga.DCIM

  setup %{conn: conn} do
    user = user_fixture()
    organization = organization_fixture()
    organization_membership_fixture(user, organization, %{role: "admin"})
    scope = Accounts.scope_for_user(user, organization.id)

    conn =
      conn
      |> log_in_user(user)
      |> put_session(:current_organization_id, organization.id)

    %{conn: conn, scope: scope}
  end

  test "creates and navigates physical containment", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/dcim/sites")

    assert has_element?(view, "#dcim-workspace")
    assert has_element?(view, "#sites-empty")
    assert has_element?(view, "#new-site-form")
    assert has_element?(view, "#primary-navigation", "Physical inventory")

    redirect =
      view
      |> form("#new-site-form", site: %{name: "Tokyo DC", slug: "tokyo-dc", time_zone: "Etc/UTC"})
      |> render_submit()

    {path, _flash} = assert_redirect(view)
    assert path =~ "/dcim/sites/"

    {:ok, site_view, _html} = follow_redirect(redirect, conn)
    assert has_element?(site_view, "#site-detail")
    assert has_element?(site_view, "#new-location-form")
  end

  test "shows rack elevations, unplaced resources, and findings", %{conn: conn, scope: scope} do
    {:ok, site} =
      DCIM.create_site(
        scope,
        %{name: "Berlin", lifecycle_state: "active"},
        %{slug: "berlin", status: "active"}
      )

    {:ok, rack} =
      DCIM.create_rack(
        scope,
        %{name: "BER-R01", lifecycle_state: "active"},
        %{site_id: site.id, height_units: 12, width: "19_inch", status: "active"}
      )

    {:ok, resource} =
      Renga.Inventory.create_resource(scope, %{
        kind: "server",
        name: "compute-01",
        lifecycle_state: "active"
      })

    {:ok, unplaced} =
      Renga.Inventory.create_resource(scope, %{
        kind: "server",
        name: "compute-02",
        lifecycle_state: "active"
      })

    {:ok, _placement} =
      DCIM.put_current_placement(scope, resource.id, %{
        rack_id: rack.id,
        position: 4,
        height_units: 2,
        face: "front"
      })

    {:ok, _finding} =
      DCIM.put_placement_finding(scope, resource.id, %{
        kind: "confirmed_placement_conflict",
        message: "Import reports a different rack"
      })

    {:ok, rack_view, _html} = live(conn, ~p"/dcim/racks/#{rack.id}")
    assert has_element?(rack_view, "#rack-elevation")
    assert has_element?(rack_view, "#rack-unit-4", "compute-01")
    assert has_element?(rack_view, "#rack-unit-4", "Active · Inferred")
    assert has_element?(rack_view, "#unplaced-resources")
    assert has_element?(rack_view, "#rack-placement-form")

    rack_view
    |> form("#rack-placement-form",
      placement: %{resource_id: unplaced.id, position: "8", height_units: "1", face: "rear"}
    )
    |> render_submit()

    assert has_element?(rack_view, "#rack-unit-8", "compute-02")
    assert has_element?(rack_view, "#rack-unit-8", "Active · Confirmed")

    {:ok, findings_view, _html} = live(conn, ~p"/dcim/placement-findings")
    assert has_element?(findings_view, "#placement-findings")
    assert has_element?(findings_view, "[id^='finding-']", "compute-01")
  end

  test "read-only members do not receive mutation forms", %{conn: conn, scope: scope} do
    membership =
      Renga.Repo.get_by!(Renga.Accounts.OrganizationMembership,
        organization_id: scope.organization_id,
        user_id: scope.user.id
      )

    {:ok, _membership} = Accounts.update_organization_membership(membership, %{role: "member"})

    {:ok, view, _html} = live(conn, ~p"/dcim/sites")
    refute has_element?(view, "#new-site-form")
  end
end
