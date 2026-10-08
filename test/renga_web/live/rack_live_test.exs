defmodule RengaWeb.RackLiveTest do
  use RengaWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Renga.AccountsFixtures
  import Renga.InventoryFixtures
  import Renga.TriageFixtures

  alias Renga.Accounts
  alias Renga.DCIM
  alias Renga.Inventory

  setup do
    organization = organization_fixture()
    {admin_conn, admin} = member(organization, "admin")
    {member_conn, _member} = member(organization, "member")

    {:ok, site} = DCIM.create_site(admin, %{name: "DC1"}, %{slug: "dc1"})
    {:ok, hall} = DCIM.create_location(admin, %{name: "Hall A"}, %{site_id: site.id})

    {:ok, rack} =
      DCIM.create_rack(admin, %{name: "R12"}, %{
        site_id: site.id,
        location_id: hall.id,
        height_units: 12
      })

    {:ok, other_rack} = DCIM.create_rack(admin, %{name: "R13"}, %{site_id: site.id})

    %{
      admin_conn: admin_conn,
      member_conn: member_conn,
      admin: admin,
      site: site,
      hall: hall,
      rack: rack,
      other_rack: other_rack
    }
  end

  test "draws devices as blocks on each face they occupy", context do
    %{admin: admin, rack: rack} = context
    web = server_fixture(admin, "web-01")
    nas = resource_fixture(admin, "storage", "nas-01")
    {:ok, web_placement} = place(admin, web, rack, position: 4, height_units: 2, face: "front")
    {:ok, nas_placement} = place(admin, nas, rack, position: 8, height_units: 1, face: "full")

    {:ok, view, _html} = live(context.admin_conn, ~p"/places/racks/#{rack}")

    assert has_element?(view, "#rack-face-front-view #block-front-#{web_placement.id}", "web-01")
    assert has_element?(view, "#block-front-#{web_placement.id}[data-status=inferred]", "2U")

    assert has_element?(
             view,
             "#rack-face-rear-view #block-rear-#{nas_placement.id}",
             "Full depth"
           )

    assert has_element?(view, "#rack-face-front-view #block-front-#{nas_placement.id}")
    refute has_element?(view, "#rack-face-rear-view #block-rear-#{web_placement.id}")

    assert has_element?(view, "#rack-face-front-view h2", "9U free")
    assert has_element?(view, "#unit-front-12")
    refute has_element?(view, "#unit-front-5")
    assert has_element?(view, "#unit-rear-5")
  end

  test "places a device by choosing a free unit from a list", context do
    %{admin: admin, rack: rack, hall: hall, site: site} = context
    tor = server_fixture(admin, "tor-01")
    in_hall = server_fixture(admin, "in-hall-01")
    {:ok, _} = DCIM.put_current_placement(admin, tor.id, %{rack_id: rack.id})

    {:ok, _} =
      DCIM.put_current_placement(admin, in_hall.id, %{site_id: site.id, location_id: hall.id})

    {:ok, view, _html} = live(context.admin_conn, ~p"/places/racks/#{rack}")

    assert has_element?(view, "#placeable-in-rack #placeable-#{tor.id}", "tor-01")
    assert has_element?(view, "#placeable-at-location", "At Hall A")
    assert has_element?(view, "#placeable-#{in_hall.id}", "in-hall-01")

    view |> element("#placeable-#{in_hall.id}-place") |> render_click()
    assert has_element?(view, "#place-resource option[selected][value='#{in_hall.id}']")
    assert has_element?(view, "#place-unit option[value='12']", "U12")

    view
    |> form("#place-form", place: %{resource_id: in_hall.id, face: "rear", position: "3"})
    |> render_change()

    view |> form("#place-form") |> render_submit()

    assert render(view) =~ "in-hall-01 placed at U3"
    assert has_element?(view, "#rack-face-rear-view [id^=block-rear-]", "in-hall-01")
    refute has_element?(view, "#placeable-#{in_hall.id}")
    assert DCIM.rack_elevation(admin, rack.id).rear |> hd() |> Map.fetch!(:position) == 3
  end

  test "choosing a free unit opens the panel at that unit", context do
    %{admin: admin, rack: rack} = context
    web = server_fixture(admin, "web-01")

    {:ok, view, _html} = live(context.admin_conn, ~p"/places/racks/#{rack}")

    view |> element("#unit-front-7") |> render_click()
    assert has_element?(view, "#place-unit option[selected][value='7']")

    view |> form("#place-form") |> render_submit()
    assert has_element?(view, "#rack-face-front-view [id^=block-front-]", "web-01")
    assert [%{position: 7}] = DCIM.rack_elevation(admin, rack.id).front
    assert web.id == hd(DCIM.rack_elevation(admin, rack.id).front).resource.id
  end

  test "a device seen here but recorded elsewhere is dashed and placed in one step", context do
    %{admin: admin, rack: rack, other_rack: other_rack} = context
    web = server_fixture(admin, "web-01")

    {:ok, _} =
      place(admin, web, other_rack, position: 3, height_units: 1, face: "front", confirmed: true)

    observe!(admin, web, rack_identifier: "R12", position: 6, height_units: 1, face: "front")

    {:ok, view, _html} = live(context.admin_conn, ~p"/places/racks/#{rack}")

    assert has_element?(view, "#observed-#{web.id}", "recorded at DC1 / R13")
    assert has_element?(view, "#ghost-front-#{web.id}[data-observed=evidence]", "Seen here")

    view |> element("#observed-#{web.id}-place") |> render_click()

    assert render(view) =~ "web-01 placed at U6"
    refute has_element?(view, "#observed")
    refute has_element?(view, "#ghost-front-#{web.id}")
    assert has_element?(view, "#rack-face-front-view [data-status=confirmed]", "web-01")
  end

  test "shows one face at a time on a phone, chosen in the URL", context do
    {:ok, view, _html} = live(context.admin_conn, ~p"/places/racks/#{context.rack}")
    assert has_element?(view, "#rack-face-rear-view.hidden")
    refute has_element?(view, "#rack-face-front-view.hidden")
    assert has_element?(view, "#rack-face-front[aria-current]")

    {:ok, view, _html} = live(context.admin_conn, ~p"/places/racks/#{context.rack}?face=rear")
    assert has_element?(view, "#rack-face-front-view.hidden")
    refute has_element?(view, "#rack-face-rear-view.hidden")
  end

  test "picks up placements made elsewhere", context do
    %{admin: admin, rack: rack} = context
    {:ok, view, _html} = live(context.admin_conn, ~p"/places/racks/#{rack}")
    web = server_fixture(admin, "web-01")

    {:ok, _} = DCIM.place_in_rack(admin, web.id, rack.id, 9, "front")
    send(view.pid, :reload)

    assert has_element?(view, "#rack-face-front-view [id^=block-front-]", "web-01")
  end

  test "members read the rack but cannot place devices", context do
    %{admin: admin, rack: rack, other_rack: other_rack} = context
    server_fixture(admin, "unplaced-01")
    web = server_fixture(admin, "web-01")

    {:ok, _} =
      place(admin, web, other_rack, position: 3, height_units: 1, face: "front", confirmed: true)

    observe!(admin, web, rack_identifier: "R12", position: 6, height_units: 1, face: "front")

    {:ok, view, _html} = live(context.member_conn, ~p"/places/racks/#{rack}")

    assert has_element?(view, "#placeable-unplaced", "unplaced-01")
    assert has_element?(view, "#observed-#{web.id}")
    refute has_element?(view, "#observed-#{web.id}-place")
    refute has_element?(view, "#place-device")
    refute has_element?(view, "#place-panel")
    refute has_element?(view, "button#unit-front-1")
    assert has_element?(view, "div#unit-front-1")
  end

  defp place(scope, resource, rack, attrs) do
    DCIM.put_current_placement(scope, resource.id, Map.merge(%{rack_id: rack.id}, Map.new(attrs)))
  end

  defp observe!(scope, resource, attrs) do
    {:ok, source} =
      Inventory.create_source(scope, %{kind: "manual", name: "scan-#{resource.name}"})

    {:ok, observation} =
      Inventory.create_observation(scope, source.id, %{
        idempotency_key: "scan-#{resource.name}",
        observed_at: DateTime.utc_now(),
        payload: %{}
      })

    {:ok, _evidence} =
      DCIM.create_placement_evidence(
        scope,
        source.id,
        observation.id,
        resource.id,
        Map.merge(%{observed_at: DateTime.utc_now(), confidence: 80}, Map.new(attrs))
      )

    {:ok, _placement} = DCIM.reconcile_placement_evidence(scope, resource.id)
  end

  defp member(organization, role) do
    user = user_fixture()
    organization_membership_fixture(user, organization, %{role: role})

    conn =
      build_conn()
      |> log_in_user(user)
      |> put_session(:current_organization_id, organization.id)

    {conn, Accounts.scope_for_user(user, organization.id)}
  end
end
