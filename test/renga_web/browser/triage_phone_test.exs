defmodule RengaWeb.Browser.TriagePhoneTest do
  @moduledoc """
  The on-floor phone task from RFD 8 at 390px: open a resource from triage,
  set its owner, and place it in a rack, one item at a time, with the panel
  on screen and 44px tap targets.
  """
  use PhoenixTest.Playwright.Case, async: true

  import Renga.AccountsFixtures
  import Renga.InventoryFixtures

  alias Renga.DCIM
  alias Renga.Inventory
  alias Renga.Teams

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

    {:ok, server} =
      Inventory.create_resource(scope, %{
        kind: "server",
        name: "web-01",
        lifecycle_state: "active"
      })

    {:ok, _team} = Teams.create_team(scope, %{"name" => "Platform"})
    {:ok, site} = DCIM.create_site(scope, %{name: "DC1"}, %{slug: "dc1"})
    {:ok, rack} = DCIM.create_rack(scope, %{name: "R12"}, %{site_id: site.id, height_units: 42})

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

    %{conn: conn, server: server, rack: rack}
  end

  test "sets an owner and places a resource at phone width", %{conn: conn} = context do
    conn
    |> visit("/inbox?group=triage")
    |> assert_has("body .phx-connected")
    |> click("#triage-link-#{context.server.id}")
    |> assert_has("#triage-panel [role=dialog]", text: "web-01")
    |> evaluate(fits_screen_js(), &assert(&1 == true))
    |> evaluate(tap_heights_js(), fn heights -> assert Enum.all?(heights, &(round(&1) >= 44)) end)
    |> click_button("Set owner")
    |> refute_has("#triage-owner")
    |> select("Rack", option: "DC1 / R12", exact: false)
    |> click_button("Place")
    |> refute_has("#triage-placement")
    |> assert_has("#triage-hardware")
  end

  defp fits_screen_js do
    """
    (() => {
      const box = document.querySelector('#triage-panel [role=dialog]').getBoundingClientRect();
      return box.left >= 0 && box.right <= document.documentElement.clientWidth + 0.5 &&
        document.documentElement.scrollWidth <= document.documentElement.clientWidth;
    })()
    """
  end

  defp tap_heights_js do
    """
    Array.from(document.querySelectorAll(
      '#triage-owner-team, #triage-owner-save, #triage-placement-rack, #triage-placement-save'
    )).map((element) => element.getBoundingClientRect().height)
    """
  end
end
