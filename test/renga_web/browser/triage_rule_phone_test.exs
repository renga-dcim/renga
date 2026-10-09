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
  import Renga.TriageFixtures

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

    {:ok, other} =
      Inventory.create_resource(scope, %{
        kind: "server",
        name: "web-02",
        lifecycle_state: "active"
      })

    {:ok, _host} = Inventory.create_host(scope, other.id, %{hostname: "web-02"})
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
    |> assert_has("#rule-preview-will-set", text: "Sets the owner on 2 resources")
    |> evaluate(fits_screen_js(), &assert(&1 == true))
    |> click_button("Save and apply")
    |> assert_has("#rules-ownership li", text: "owned by Platform")
  end

  test "turns a triage pattern into a rule at phone width", %{conn: conn} do
    conn
    |> visit("/inbox?group=triage")
    |> assert_has("body .phx-connected")
    |> assert_has("#triage-pattern-row-aG9zdG5hbWUtd2ViLQ", text: "web-01, web-02")
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
    "document.querySelector('#triage-pattern-rule-aG9zdG5hbWUtd2ViLQ').getBoundingClientRect().height"
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
      |> assert_has("#rule-preview-will-set", text: "Sets the owner on 2 resources")
      |> evaluate(fits_screen_js(), &assert(&1 == true))

    refute TriageRules.get_rule(context.scope, rule.id).enabled
    assert Renga.Repo.reload!(context.server).owner_team_id == nil

    session
    |> click_button("Save and apply")
    |> assert_has("#rule-#{rule.id}[data-enabled=true]")

    assert Renga.Repo.reload!(context.server).owner_team_id == context.team.id
  end

  test "distinct label patterns keep their identity when LiveView removes one", context do
    first = report_fixture(context.scope, "alpha", labels: %{"team" => "ops.us"})
    report_fixture(context.scope, "beta", labels: %{"team" => "ops.us"})
    report_fixture(context.scope, "gamma", labels: %{"team" => "ops-us"})
    report_fixture(context.scope, "delta", labels: %{"team" => "ops-us"})

    session =
      context.conn
      |> visit("/inbox?group=triage")
      |> assert_has("body .phx-connected")
      |> assert_has("#triage-patterns li", text: "Label team=ops.us")
      |> assert_has("#triage-patterns li", text: "Label team=ops-us")
      |> evaluate(
        """
        (() => {
          const ids = [...document.querySelectorAll('#triage-patterns [id]')].map(el => el.id);
          return ids.length === new Set(ids).size;
        })()
        """,
        &assert(&1 == true)
      )

    {:ok, _resource} = Teams.set_owner(context.scope, first, context.team.id)

    session
    |> refute_has("#triage-patterns li", text: "Label team=ops.us")
    |> assert_has("#triage-patterns li", text: "Label team=ops-us")
    |> assert_has("#triage-patterns a[href*='label_value=ops-us']", text: "Create a rule")
    |> refute_has("#triage-patterns a[href*='label_value=ops.us']")
  end

  defp fits_screen_js do
    """
    (() => {
      const box = document.querySelector('#rule-panel [role=dialog]').getBoundingClientRect();
      return box.left >= 0 && box.right <= document.documentElement.clientWidth + 0.5 &&
        document.documentElement.scrollWidth <= document.documentElement.clientWidth;
    })()
    """
  end
end
