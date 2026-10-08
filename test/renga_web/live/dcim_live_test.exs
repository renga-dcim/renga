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

  test "read-only members do not receive mutation forms", %{conn: conn, scope: scope} do
    membership =
      Renga.Repo.get_by!(Renga.Accounts.OrganizationMembership,
        organization_id: scope.organization_id,
        user_id: scope.user.id
      )

    {:ok, _membership} = Accounts.update_organization_membership(membership, %{role: "member"})

    {:ok, view, _html} = live(conn, ~p"/places")
    refute has_element?(view, "#new-site-form")
  end
end
