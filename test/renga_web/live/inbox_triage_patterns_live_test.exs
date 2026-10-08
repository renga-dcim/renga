defmodule RengaWeb.InboxTriagePatternsLiveTest do
  use RengaWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Renga.AccountsFixtures
  import Renga.InventoryFixtures
  import Renga.TriageFixtures

  alias Renga.Repo
  alias Renga.Teams
  alias Renga.TriageRules

  setup do
    organization = organization_fixture()
    {admin_conn, admin} = member(organization, "admin")
    {member_conn, _member} = member(organization, "member")
    {:ok, team} = Teams.create_team(admin, %{"name" => "Platform"})
    web1 = server_fixture(admin, "web-01", hostname: "web-01")
    web2 = server_fixture(admin, "web-02", hostname: "web-02")

    %{
      admin_conn: admin_conn,
      member_conn: member_conn,
      admin: admin,
      team: team,
      web1: web1,
      web2: web2
    }
  end

  test "a triage pattern opens its suggested rule, prefilled, and saving clears it", context do
    {:ok, inbox, _html} = live(context.admin_conn, ~p"/inbox?group=triage")

    assert has_element?(inbox, "#triage-pattern-hostname-web-", "Hostname web-*")
    assert has_element?(inbox, "#triage-pattern-hostname-web-[data-fact=owner]", "web-01, web-02")

    {:ok, rules, _html} =
      inbox
      |> element("#triage-pattern-hostname-web--rule")
      |> render_click()
      |> follow_redirect(context.admin_conn)

    assert has_element?(rules, "#rule-panel[data-initial-show=true]")
    assert has_element?(rules, "#rule_hostname_pattern[value='web-*']")
    assert has_element?(rules, "#rule_name[value='Hostnames web-*']")
    assert has_element?(rules, "#rule-preview", "Complete the rule")

    rules
    |> form("#rule-form", rule: %{team_id: context.team.id})
    |> render_change()

    assert has_element?(rules, "#rule-preview-will-set", "Sets the owner on 2 resources")

    rules |> form("#rule-form") |> render_submit()
    assert_patch(rules, ~p"/settings/triage-rules")

    assert [%{hostname_pattern: "web-*"}] = TriageRules.list_rules(context.admin)
    assert Repo.reload!(context.web1).owner_team_id == context.team.id

    {:ok, inbox, _html} = live(context.admin_conn, ~p"/inbox?group=triage")
    refute has_element?(inbox, "#triage-pattern-hostname-web-")
  end

  test "patterns follow the missing-fact filter", context do
    {:ok, view, _html} = live(context.admin_conn, ~p"/inbox?group=triage&missing=placement")
    refute has_element?(view, "#triage-pattern-hostname-web-")

    {:ok, view, _html} = live(context.admin_conn, ~p"/inbox?group=triage&missing=hardware_type")
    refute has_element?(view, "#triage-patterns")
  end

  test "members see patterns but cannot create rules from them", context do
    {:ok, view, _html} = live(context.member_conn, ~p"/inbox?group=triage")

    assert has_element?(view, "#triage-pattern-hostname-web-")
    refute has_element?(view, "#triage-pattern-hostname-web--rule")

    {:ok, rules, _html} =
      live(context.member_conn, ~p"/settings/triage-rules?kind=ownership&hostname_pattern=web-*")

    refute has_element?(rules, "#rule-panel")
  end

  defp member(organization, role) do
    user = user_fixture()
    organization_membership_fixture(user, organization, %{role: role})

    conn =
      build_conn()
      |> log_in_user(user)
      |> put_session(:current_organization_id, organization.id)

    {conn, Renga.Accounts.scope_for_user(user, organization.id)}
  end
end
