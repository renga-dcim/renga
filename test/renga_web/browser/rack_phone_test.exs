defmodule RengaWeb.Browser.RackPhoneTest do
  @moduledoc """
  The on-floor rack tasks from RFD 8 at 390px: read the elevation one face
  at a time, scrolling vertically, and place a device by choosing a unit
  from a list instead of dragging, with 44px tap targets throughout.
  """
  use PhoenixTest.Playwright.Case, async: true

  import Renga.AccountsFixtures
  import Renga.InventoryFixtures
  import Renga.TriageFixtures

  alias Renga.DCIM

  @moduletag :playwright
  @moduletag browser_context_opts: [
               has_touch: true,
               is_mobile: true,
               viewport: %{width: 390, height: 844}
             ]

  setup %{conn: conn} do
    organization = organization_fixture()
    user = user_fixture()
    organization_membership_fixture(user, organization, %{role: "admin"})
    scope = Renga.Accounts.scope_for_user(user, organization.id)

    {:ok, site} = DCIM.create_site(scope, %{name: "DC1"}, %{slug: "dc1"})
    {:ok, rack} = DCIM.create_rack(scope, %{name: "R12"}, %{site_id: site.id, height_units: 42})
    web = server_fixture(scope, "web-01")
    nas = resource_fixture(scope, "storage", "nas-01")
    server_fixture(scope, "db-01")

    {:ok, _} =
      DCIM.put_current_placement(scope, web.id, %{
        rack_id: rack.id,
        position: 20,
        height_units: 2,
        face: "front"
      })

    {:ok, _} =
      DCIM.put_current_placement(scope, nas.id, %{
        rack_id: rack.id,
        position: 10,
        height_units: 4,
        face: "rear"
      })

    conn =
      add_session_cookie(
        conn,
        [
          value: %{
            user_token: Renga.Accounts.generate_user_session_token(user),
            current_organization_id: organization.id
          }
        ],
        RengaWeb.Endpoint.session_options()
      )

    %{conn: conn, rack: rack}
  end

  test "reads one face at a time and places a device from a unit list", %{conn: conn} = context do
    conn
    |> visit("/places/racks/#{context.rack.id}")
    |> assert_has("body .phx-connected")
    |> assert_has("#rack-face-front-view", text: "web-01")
    |> refute_has("#rack-face-rear-view", text: "nas-01")
    |> evaluate(fits_width_js(), &assert(&1 == true))
    |> click_link("Rear")
    |> assert_has("#rack-face-rear-view", text: "nas-01")
    |> refute_has("#rack-face-front-view", text: "web-01")
    |> click_button("#place-device", "Place a device")
    |> assert_has("#place-panel [role=dialog]")
    |> select("#place-resource", "Device", option: "db-01 (1U)", exact: false)
    |> select("#place-face", "Face", option: "Rear", exact: false)
    |> select("#place-unit", "Unit", option: "U30", exact: false)
    |> evaluate(tap_heights_js(), fn heights -> assert Enum.all?(heights, &(round(&1) >= 44)) end)
    |> click_button("#place-save", "Place")
    |> assert_has("#rack-face-rear-view", text: "db-01")
  end

  defp fits_width_js do
    "document.documentElement.scrollWidth <= window.innerWidth"
  end

  defp tap_heights_js do
    """
    Array.from(document.querySelectorAll(
      '#rack-face-front, #rack-face-rear, #place-resource, #place-face, #place-unit, #place-save'
    )).map((element) => element.getBoundingClientRect().height)
    """
  end
end
