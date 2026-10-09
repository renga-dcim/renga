defmodule RengaWeb.Browser.VrfsTest do
  @moduledoc """
  The VRF list in a real browser: an admin creates, renames, and deletes a
  VRF through the side panel and confirmation dialog, and at phone width the
  list stays readable without horizontal scrolling and without controls,
  because VRFs are not edited on a phone.
  """
  use PhoenixTest.Playwright.Case, async: true

  import Renga.AccountsFixtures
  import Renga.InventoryFixtures
  import Renga.TopologyFixtures

  @moduletag :playwright

  setup %{conn: conn} do
    organization = organization_fixture()
    user = user_fixture()
    organization_membership_fixture(user, organization, %{role: "admin"})
    scope = Renga.Accounts.scope_for_user(user, organization.id)

    blue =
      vrf_fixture(scope, "blue", %{
        route_distinguisher: "65000:4294967295",
        description: "Tenant network for the blue customer"
      })

    prefix_fixture(scope, "10.0.0.0/24", %{vrf: "blue"})
    vrf_fixture(scope, "tenant-" <> String.duplicate("blue", 20))

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

    %{conn: conn, scope: scope, blue: blue}
  end

  test "an admin creates, renames, and deletes a VRF", context do
    session =
      context.conn
      |> visit("/network/vrfs")
      |> assert_has("body .phx-connected")
      |> PhoenixTest.Playwright.click("#new-vrf")
      |> assert_has("#vrf-panel [role=dialog]", text: "New VRF")
      |> fill_in("#vrf-form input[name='vrf[name]']", "Name", with: "BLUE")
      |> PhoenixTest.Playwright.click("#save-vrf")
      |> assert_has("#vrf-panel [role=dialog]", text: "is already a VRF in this organization")
      |> fill_in("#vrf-form input[name='vrf[name]']", "Name", with: "red")
      |> PhoenixTest.Playwright.click("#save-vrf")
      |> assert_has("#flash-info", text: "VRF red created")
      |> refute_has("#vrf-panel [role=dialog]")

    red = Renga.IPAM.get_vrf_by_name(context.scope, "red")

    session
    |> PhoenixTest.Playwright.click("#vrf-#{red.id}-edit")
    |> assert_has("#vrf-panel [role=dialog]", text: "Edit red")
    |> fill_in("#vrf-form input[name='vrf[name]']", "Name", with: "green")
    |> PhoenixTest.Playwright.click("#save-vrf")
    |> assert_has("#vrf-#{red.id}", text: "green")
    |> PhoenixTest.Playwright.click("#vrf-#{red.id}-delete")
    |> assert_has("#delete-vrf-#{red.id} [role=alertdialog]", text: "Delete green?")
    |> PhoenixTest.Playwright.click("#delete-vrf-#{red.id}-confirm")
    |> assert_has("#flash-info", text: "VRF green deleted")
    |> refute_has("#vrf-#{red.id}")
    |> evaluate(
      "document.getElementById('vrf-#{context.blue.id}-delete').disabled",
      &assert(&1 == true)
    )
  end

  @tag browser_context_opts: [
         has_touch: true,
         is_mobile: true,
         viewport: %{width: 390, height: 844}
       ]
  test "VRFs are readable but not editable on a phone", context do
    context.conn
    |> visit("/network/vrfs")
    |> assert_has("body .phx-connected")
    |> assert_has("#vrf-#{context.blue.id}", text: "blue")
    |> evaluate(visible_js("new-vrf"), &assert(&1 == false))
    |> evaluate(visible_js("vrf-#{context.blue.id}-edit"), &assert(&1 == false))
    |> evaluate(visible_js("vrf-#{context.blue.id}-prefixes"), &assert(&1 == true))
    |> evaluate(
      "document.documentElement.scrollWidth <= document.documentElement.clientWidth",
      &assert(&1 == true)
    )
    # The list itself fits too, so each table's prefix count is never
    # scrolled out of view.
    |> evaluate(
      "(el => el.scrollWidth <= el.clientWidth)(document.getElementById('vrf-list').closest('div'))",
      &assert(&1 == true)
    )
  end

  defp visible_js(id), do: "document.getElementById('#{id}').checkVisibility()"
end
