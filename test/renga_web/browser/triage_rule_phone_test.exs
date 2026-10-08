defmodule RengaWeb.Browser.TriageRulePhoneTest do
  @moduledoc """
  Writing a triage rule at 390px: the side panel stays on screen, switching
  kinds swaps the condition fields, and the preview updates as the rule
  becomes complete, before anything is saved. A triage pattern in the Inbox
  opens its suggested rule already filled in.
  """
  use PhoenixTest.Playwright.Case, async: true

  import Renga.AccountsFixtures
  import Renga.InventoryFixtures

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

    {:ok, _host} = Inventory.create_host(scope, server.id, %{hostname: "web-01"})

    {:ok, other} =
      Inventory.create_resource(scope, %{
        kind: "server",
        name: "web-02",
        lifecycle_state: "active"
      })

    {:ok, _host} = Inventory.create_host(scope, other.id, %{hostname: "web-02"})
    {:ok, _team} = Teams.create_team(scope, %{"name" => "Platform"})

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

    %{conn: conn}
  end

  test "previews and saves an ownership rule at phone width", %{conn: conn} do
    conn
    |> visit("/settings/triage-rules")
    |> assert_has("body .phx-connected")
    |> click_button("New rule")
    |> assert_has("#rule-panel [role=dialog]")
    |> select("Kind", option: "Ownership", exact: false)
    |> assert_has("#rule_hostname_pattern")
    |> fill_in("Name", with: "Web")
    |> fill_in("Hostname pattern", with: "web-*")
    |> select("Owning team", option: "Platform", exact: false)
    |> assert_has("#rule-preview-will-set", text: "Sets the owner on 2 resources")
    |> evaluate(fits_screen_js(), &assert(&1 == true))
    |> click_button("Save and apply")
    |> assert_has("#rules-ownership li", text: "owned by Platform")
  end

  test "turns a triage pattern into a rule at phone width", %{conn: conn} do
    conn
    |> visit("/inbox?group=triage")
    |> assert_has("body .phx-connected")
    |> assert_has("#triage-pattern-hostname-web-", text: "web-01, web-02")
    |> evaluate(pattern_link_height_js(), &assert(round(&1) >= 44))
    |> click_link("Create a rule")
    |> assert_has("#rule-panel [role=dialog]")
    |> assert_has("#rule_hostname_pattern[value='web-*']")
    |> select("Owning team", option: "Platform", exact: false)
    |> assert_has("#rule-preview-will-set", text: "Sets the owner on 2 resources")
    |> evaluate(fits_screen_js(), &assert(&1 == true))
    |> click_button("Save and apply")
    |> assert_has("#rules-ownership li", text: "hostname web-*")
  end

  defp pattern_link_height_js do
    "document.querySelector('#triage-pattern-hostname-web--rule').getBoundingClientRect().height"
  end

  defp fits_screen_js do
    """
    (() => {
      const box = document.querySelector('#rule-panel [role=dialog]').getBoundingClientRect();
      return box.left >= 0 && box.right <= window.innerWidth + 0.5 &&
        document.documentElement.scrollWidth <= window.innerWidth;
    })()
    """
  end
end
