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
  alias Renga.ResourceGroups
  alias Renga.Teams
  alias Renga.TriageRules

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

    %{conn: conn, scope: scope, server: server, rack: rack}
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

  test "accepts a group suggestion at phone width", context do
    {:ok, _host} = Inventory.create_host(context.scope, context.server.id, %{hostname: "web-01"})
    {:ok, group} = ResourceGroups.create_group(context.scope, %{name: "Web tier"})

    assert {:ok, %{applied: 1}} =
             TriageRules.create_rule(context.scope, %{
               "kind" => "group",
               "name" => "Web hosts",
               "hostname_pattern" => "web-*",
               "resource_group_id" => group.id
             })

    [suggestion] = ResourceGroups.list_suggestions(context.scope)

    context.conn
    |> visit("/inbox?group=triage")
    |> assert_has("body .phx-connected")
    |> assert_has("#group-suggestion-#{suggestion.id}", text: "Web tier")
    |> evaluate("matchMedia('(pointer: coarse)').matches", &assert(&1 == true))
    |> evaluate(no_horizontal_scroll_js(), &assert(&1 == true))
    |> evaluate(suggestion_tap_heights_js(suggestion.id), fn heights ->
      assert Enum.all?(heights, &(round(&1) >= 44))
    end)
    |> click("#group-suggestion-#{suggestion.id}-accept")
    |> refute_has("#group-suggestion-#{suggestion.id}")
    |> assert_has("#flash-info", text: "Added to the group")

    assert [%{group: %{id: id}, direct: true}] =
             ResourceGroups.list_resource_groups(context.scope, context.server.id)

    assert id == group.id
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

  defp no_horizontal_scroll_js do
    "document.documentElement.scrollWidth <= document.documentElement.clientWidth"
  end

  defp suggestion_tap_heights_js(id) do
    """
    Array.from(document.querySelectorAll(
      '#group-suggestion-#{id}-accept, #group-suggestion-#{id}-dismiss'
    )).map((element) => element.getBoundingClientRect().height)
    """
  end
end
