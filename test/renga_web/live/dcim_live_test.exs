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
    {:ok, view, _html} = live(conn, ~p"/places")

    assert has_element?(view, "#dcim-workspace")
    assert has_element?(view, "#sites-empty")
    assert has_element?(view, "#new-site-form")
    assert has_element?(view, "#primary-navigation a[aria-current='page']", "Places")

    redirect =
      view
      |> form("#new-site-form", site: %{name: "Tokyo DC", slug: "tokyo-dc", time_zone: "Etc/UTC"})
      |> render_submit()

    {path, _flash} = assert_redirect(view)
    assert path =~ "/places/sites/"

    {:ok, site_view, _html} = follow_redirect(redirect, conn)
    assert has_element?(site_view, "#site-detail")
    assert has_element?(site_view, "#new-location-form")
  end

  test "placement findings on racked devices reach the Inbox", %{conn: conn, scope: scope} do
    {:ok, site} = DCIM.create_site(scope, %{name: "Berlin"}, %{slug: "berlin"})

    {:ok, rack} =
      DCIM.create_rack(scope, %{name: "BER-R01"}, %{site_id: site.id, height_units: 12})

    {:ok, resource} =
      Renga.Inventory.create_resource(scope, %{kind: "server", name: "compute-01"})

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

    {:ok, rack_view, _html} = live(conn, ~p"/places/racks/#{rack.id}")
    assert has_element?(rack_view, "#rack-elevation", "compute-01")

    {:ok, inbox, _html} = live(conn, ~p"/inbox?domain=placement")
    assert has_element?(inbox, "#findings [data-list-row]", "compute-01")
  end

  test "a site lists its locations as a tree and its racks with how full they are",
       %{conn: conn, scope: scope} do
    {:ok, site} = DCIM.create_site(scope, %{name: "DC1"}, %{slug: "dc1"})
    {:ok, hall} = DCIM.create_location(scope, %{name: "Hall A"}, %{site_id: site.id})

    {:ok, row} =
      DCIM.create_location(scope, %{name: "Row 3"}, %{site_id: site.id, parent_id: hall.id})

    {:ok, cage} =
      DCIM.create_location(scope, %{name: "Cage 9"}, %{site_id: site.id, parent_id: row.id})

    {:ok, rack} =
      DCIM.create_rack(scope, %{name: "R12"}, %{
        site_id: site.id,
        location_id: cage.id,
        height_units: 10
      })

    {:ok, server} = Renga.Inventory.create_resource(scope, %{kind: "server", name: "web-01"})

    {:ok, _} =
      DCIM.put_current_placement(scope, server.id, %{
        rack_id: rack.id,
        position: 1,
        height_units: 3,
        face: "full"
      })

    {:ok, sites, _html} = live(conn, ~p"/places")
    assert has_element?(sites, "#site-#{site.id}", "DC1")
    assert has_element?(sites, "#site-#{site.id} td:nth-child(2)", "3")
    assert has_element?(sites, "#site-#{site.id} td:nth-child(3)", "1")

    {:ok, view, _html} = live(conn, ~p"/places/sites/#{site.id}")
    assert has_element?(view, "#site-locations #location-#{hall.id}[data-depth='0']", "Hall A")
    assert has_element?(view, "#location-#{row.id}[data-depth='1']", "Row 3")
    assert has_element?(view, "#location-#{cage.id}[data-depth='2']", "Cage 9")
    assert has_element?(view, "#site-racks #rack-#{rack.id} [data-used='3']", "3/10U")

    {:ok, location, _html} = live(conn, ~p"/places/locations/#{cage.id}")
    assert has_element?(location, "#location-detail nav[aria-label=Breadcrumb]", "Hall A")
    assert has_element?(location, "#location-detail nav[aria-label=Breadcrumb]", "Row 3")
    assert has_element?(location, "#location-racks #rack-#{rack.id}", "R12")

    {:ok, racks, _html} = live(conn, ~p"/places/racks")
    assert has_element?(racks, "#racks #rack-#{rack.id}", "DC1 / Cage 9")
    assert has_element?(racks, "#rack-#{rack.id} [data-used='3']")
  end

  test "a new rack offers the locations of the site it is in", %{conn: conn, scope: scope} do
    {:ok, site} = DCIM.create_site(scope, %{name: "DC1"}, %{slug: "dc1"})
    {:ok, hall} = DCIM.create_location(scope, %{name: "Hall A"}, %{site_id: site.id})

    {:ok, view, _html} = live(conn, ~p"/places/racks")
    refute has_element?(view, "#rack_location_id")

    view |> form("#new-rack-form", rack: %{site_id: site.id}) |> render_change()
    assert has_element?(view, "#rack_location_id option[value='#{hall.id}']", "Hall A")

    view
    |> form("#new-rack-form",
      rack: %{name: "R40", site_id: site.id, location_id: hall.id, height_units: "48"}
    )
    |> render_submit()

    {path, _flash} = assert_redirect(view)
    assert path =~ "/places/racks/"
    assert [%{height_units: 48, location_id: location_id}] = DCIM.list_racks(scope)
    assert location_id == hall.id
  end

  test "read-only members do not receive mutation forms", %{conn: conn, scope: scope} do
    membership =
      Renga.Repo.get_by!(Renga.Accounts.OrganizationMembership,
        organization_id: scope.organization_id,
        user_id: scope.user.id
      )

    {:ok, _membership} = Accounts.update_organization_membership(membership, %{role: "member"})

    {:ok, view, _html} = live(conn, ~p"/places")
    refute has_element?(view, "#new-site-form")
    refute has_element?(view, "#new-site")

    {:ok, site} = DCIM.create_site(owner_scope(scope), %{name: "DC1"}, %{slug: "dc1"})
    {:ok, site_view, _html} = live(conn, ~p"/places/sites/#{site.id}")
    refute has_element?(site_view, "#new-location")
    refute has_element?(site_view, "#new-rack-form")
  end

  # An admin scope in the same organization, for setup after a demotion.
  defp owner_scope(scope) do
    admin = user_fixture()
    organization = Renga.Repo.get!(Renga.Accounts.Organization, scope.organization_id)
    organization_membership_fixture(admin, organization, %{role: "admin"})
    Accounts.scope_for_user(admin, scope.organization_id)
  end
end
