defmodule RengaWeb.Browser.TriageRulePhoneTest do
  @moduledoc """
  Writing a triage rule at 390px: the side panel stays on screen, switching
  kinds swaps the condition fields, and the preview updates as the rule
  becomes complete, before anything is saved.
  """
  use PhoenixTest.Playwright.Case, async: true

  import Renga.AccountsFixtures
  import Renga.InventoryFixtures

  alias Renga.Inventory
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

    {:ok, _host} = Inventory.create_host(scope, server.id, %{hostname: "web-01"})
    {:ok, team} = Teams.create_team(scope, %{"name" => "Platform"})

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

    %{conn: conn, scope: scope, team: team, server: server}
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
    |> assert_has("#rule-preview-will-set", text: "Sets the owner on 1 resource")
    |> evaluate(fits_screen_js(), &assert(&1 == true))
    |> click_button("Save and apply")
    |> assert_has("#rules-ownership li", text: "owned by Platform")
  end

  test "turn on opens the impact preview before enabling at phone width", context do
    {:ok, %{rule: rule}} =
      TriageRules.create_rule(context.scope, %{
        kind: "ownership",
        name: "Web",
        enabled: false,
        hostname_pattern: "web-*",
        team_id: context.team.id
      })

    session =
      context.conn
      |> visit("/settings/triage-rules")
      |> assert_has("body .phx-connected")
      |> click_button("Turn on")
      |> assert_has("#rule-panel [role=dialog]")
      |> assert_has("#rule-preview-will-set", text: "Sets the owner on 1 resource")
      |> evaluate(fits_screen_js(), &assert(&1 == true))

    refute TriageRules.get_rule(context.scope, rule.id).enabled
    assert Renga.Repo.reload!(context.server).owner_team_id == nil

    session
    |> click_button("Save and apply")
    |> assert_has("#rule-#{rule.id}[data-enabled=true]")

    assert Renga.Repo.reload!(context.server).owner_team_id == context.team.id
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
