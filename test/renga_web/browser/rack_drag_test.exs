defmodule RengaWeb.Browser.RackDragTest do
  @moduledoc """
  Drag-to-place on the rack elevation (RFD 8, "Places"): dragging a device
  from "Can go in this rack" onto a free unit places it there, with the
  units it would cover highlighted while it is over the rack.
  """
  use PhoenixTest.Playwright.Case, async: true

  import Renga.AccountsFixtures
  import Renga.InventoryFixtures
  import Renga.TriageFixtures

  alias Renga.DCIM

  @moduletag :playwright
  @moduletag browser_context_opts: [viewport: %{width: 1360, height: 900}]

  setup %{conn: conn} do
    organization = organization_fixture()
    user = user_fixture()
    organization_membership_fixture(user, organization, %{role: "admin"})
    scope = Renga.Accounts.scope_for_user(user, organization.id)

    {:ok, site} = DCIM.create_site(scope, %{name: "DC1"}, %{slug: "dc1"})
    {:ok, rack} = DCIM.create_rack(scope, %{name: "R12"}, %{site_id: site.id, height_units: 42})
    web = server_fixture(scope, "web-01")

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

    %{conn: conn, rack: rack, scope: scope, web: web}
  end

  test "drags an unplaced device onto a free unit", %{conn: conn} = context do
    conn
    |> visit("/places/racks/#{context.rack.id}")
    |> assert_has("body .phx-connected")
    |> assert_has("#placeable-#{context.web.id}", text: "web-01")
    |> drag("#placeable-#{context.web.id}", to: "#unit-front-30")
    |> assert_has("#rack-face-front-view [id^=block-front-]", text: "web-01")
    |> refute_has("#placeable-#{context.web.id}")

    assert [%{position: 30, height: 1}] =
             DCIM.rack_elevation(context.scope, context.rack.id).front
  end
end
