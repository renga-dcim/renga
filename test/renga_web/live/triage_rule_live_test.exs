defmodule RengaWeb.TriageRuleLiveTest do
  use RengaWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Renga.AccountsFixtures
  import Renga.InventoryFixtures

  alias Renga.DCIM
  alias Renga.DCIM.CurrentPlacement
  alias Renga.Inventory
  alias Renga.Repo
  alias Renga.Teams
  alias Renga.TriageRules

  setup do
    organization = organization_fixture()
    {admin_conn, admin} = member(organization, "admin")
    {member_conn, _member} = member(organization, "member")

    {:ok, site} = DCIM.create_site(admin, %{name: "DC1"}, %{slug: "dc1"})
    {:ok, team} = Teams.create_team(admin, %{"name" => "Platform"})
    web = server!(admin, "web-01", "10.20.3.44/24")
    db = server!(admin, "db-01", "10.99.0.5/24")

    %{
      admin_conn: admin_conn,
      member_conn: member_conn,
      admin: admin,
      site: site,
      team: team,
      web: web,
      db: db
    }
  end

  test "admins preview a rule, save it, and it applies at once", context do
    {:ok, view, _html} = live(context.admin_conn, ~p"/settings/triage-rules")

    assert has_element?(view, "#rules-network_location-empty")

    view
    |> form("#rule-form", rule: %{kind: "network_location", name: "DC1", subnet: "10.20.0.0/16"})
    |> render_change()

    assert has_element?(view, "#rule-preview", "Complete the rule")

    view
    |> form("#rule-form",
      rule: %{
        kind: "network_location",
        name: "DC1",
        match_on: "subnet",
        subnet: "10.20.0.0/16",
        site_id: context.site.id
      }
    )
    |> render_change()

    assert has_element?(view, "#rule-preview-will-set", "Places 1 resource")
    assert has_element?(view, "#rule-preview li", "web-01")

    view |> form("#rule-form") |> render_submit()

    assert [rule] = TriageRules.list_rules(context.admin)

    assert has_element?(
             view,
             "#rule-#{rule.id} [data-role=sentence]",
             "reports from 10.20.0.0/16"
           )

    assert has_element?(view, "#rule-#{rule.id} [data-role=sentence]", "DC1")
    assert render(view) =~ "It placed 1 resource"

    assert %{site_id: site_id, confirmed: false} =
             Repo.get_by(CurrentPlacement, resource_id: context.web.id)

    assert site_id == context.site.id
    refute Repo.get_by(CurrentPlacement, resource_id: context.db.id)
  end

  test "an ownership rule takes a hostname pattern or a label", context do
    {:ok, view, _html} = live(context.admin_conn, ~p"/settings/triage-rules")

    view |> form("#rule-form", rule: %{kind: "ownership"}) |> render_change()
    assert has_element?(view, "#rule_hostname_pattern")
    refute has_element?(view, "#rule_subnet")

    view
    |> form("#rule-form", rule: %{kind: "ownership", match_on: "label"})
    |> render_change()

    assert has_element?(view, "#rule_label_key")
    refute has_element?(view, "#rule_hostname_pattern")

    view
    |> form("#rule-form", rule: %{kind: "ownership", match_on: "hostname"})
    |> render_change()

    view
    |> form("#rule-form",
      rule: %{
        kind: "ownership",
        name: "Web",
        match_on: "hostname",
        hostname_pattern: "web-*",
        team_id: context.team.id
      }
    )
    |> render_submit()

    assert [rule] = TriageRules.list_rules(context.admin)
    assert has_element?(view, "#rule-#{rule.id}", "hostname web-*")
    assert has_element?(view, "#rule-#{rule.id}", "owned by Platform")
    assert %{owner_rule_id: rule_id} = Repo.reload!(context.web)
    assert rule_id == rule.id

    {:ok, resource_view, _html} = live(context.admin_conn, ~p"/inventory/#{context.web}")
    assert has_element?(resource_view, "#resource-owner", "Set by the triage rule Web")

    {:ok, activity, _html} = live(context.admin_conn, ~p"/activity")
    assert render(activity) =~ "Owner set to Platform by the rule Web"
  end

  test "admins turn rules off and delete them", context do
    {:ok, %{rule: rule}} =
      TriageRules.create_rule(context.admin, %{
        "kind" => "top_of_rack",
        "name" => "Top of rack"
      })

    {:ok, view, _html} = live(context.admin_conn, ~p"/settings/triage-rules")
    assert has_element?(view, "#rule-#{rule.id}[data-enabled=true]")

    view |> element("#rule-#{rule.id}-toggle") |> render_click()
    assert has_element?(view, "#rule-#{rule.id}[data-enabled=false]", "Off")

    view |> element("#rule-#{rule.id}-edit") |> render_click()
    view |> form("#rule-form", rule: %{name: "ToR"}) |> render_submit()
    assert has_element?(view, "#rule-#{rule.id}", "ToR")

    assert has_element?(view, "#delete-rule-#{rule.id}", "already set stays")
    render_click(view, "delete", %{"id" => rule.id})
    refute has_element?(view, "#rule-#{rule.id}")
  end

  test "members read rules but cannot manage them", context do
    {:ok, %{rule: rule}} =
      TriageRules.create_rule(context.admin, %{"kind" => "top_of_rack", "name" => "ToR"})

    {:ok, view, _html} = live(context.member_conn, ~p"/settings/triage-rules")

    assert has_element?(view, "#rule-#{rule.id}", "ToR")
    assert has_element?(view, "#triage-rules-read-only")
    refute has_element?(view, "#new-rule")
    refute has_element?(view, "#rule-#{rule.id}-edit")
  end

  defp server!(scope, name, address) do
    {:ok, resource} =
      Inventory.create_resource(scope, %{kind: "server", name: name, lifecycle_state: "active"})

    {:ok, _host} = Inventory.create_host(scope, resource.id, %{hostname: name})
    {:ok, interface} = Inventory.create_interface(scope, resource.id, %{name: "eth0"})

    {:ok, _address} =
      Inventory.create_address(scope, interface.id, %{kind: "ipv4", address: address})

    resource
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
