defmodule Renga.Triage.PatternsTest do
  use Renga.DataCase, async: true

  import Renga.AccountsFixtures
  import Renga.InventoryFixtures
  import Renga.TriageFixtures

  alias Renga.Accounts
  alias Renga.DCIM
  alias Renga.Inventory
  alias Renga.Teams
  alias Renga.Triage.Patterns
  alias Renga.TriageRules

  setup do
    organization = organization_fixture()
    admin = user_fixture()
    organization_membership_fixture(admin, organization, %{role: "admin"})
    scope = Accounts.scope_for_user(admin, organization.id)
    {:ok, site} = DCIM.create_site(scope, %{name: "DC1"}, %{slug: "dc1"})
    {:ok, team} = Teams.create_team(scope, %{"name" => "Platform"})

    %{scope: scope, site: site, team: team}
  end

  test "groups unplaced resources by the /24 they hold or report from", context do
    %{scope: scope, site: site} = context
    server_fixture(scope, "web-01", address: "10.20.3.44/24")
    server_fixture(scope, "web-02", address: "10.20.3.45/24")
    placed = server_fixture(scope, "web-03", address: "10.20.3.46/24")
    server_fixture(scope, "db-01", address: "10.99.0.5/24")
    {:ok, _placement} = DCIM.put_current_placement(scope, placed.id, %{site_id: site.id})

    report_fixture(scope, "m-1", reported_from: {192, 0, 2, 5})
    report_fixture(scope, "m-2", reported_from: {192, 0, 2, 6})
    report_fixture(scope, "m-3", reported_from: {127, 0, 0, 1})
    report_fixture(scope, "m-4", reported_from: {127, 0, 0, 1})

    patterns = Patterns.list(scope, fact: :placement)

    assert %{count: 2, examples: ["web-01", "web-02"], suggestion: suggestion} =
             find(patterns, "subnet-10.20.3.0/24")

    assert %{"kind" => "network_location", "subnet" => "10.20.3.0/24"} = suggestion
    assert %{count: 2} = find(patterns, "subnet-192.0.2.0/24")
    refute find(patterns, "subnet-10.99.0.0/24")
    refute Enum.any?(patterns, &String.starts_with?(&1.id, "subnet-127."))

    # Completed with a site, the suggestion is a rule that fills the group.
    attrs = Map.put(suggestion, "site_id", site.id)
    assert {:ok, %{will_set: 2}} = TriageRules.preview(scope, attrs)
    assert {:ok, %{applied: 2}} = TriageRules.create_rule(scope, attrs)
    refute find(Patterns.list(scope), "subnet-10.20.3.0/24")
  end

  test "groups unplaced resources by intake key", %{scope: scope} do
    {:ok, {key, _token}} = Inventory.create_intake_api_key(scope, %{name: "DC1 fleet"})
    report_fixture(scope, "m-1", intake_api_key_id: key.id)
    report_fixture(scope, "m-2", intake_api_key_id: key.id)

    assert %{count: 2, label: "Report through DC1 fleet", suggestion: suggestion} =
             find(Patterns.list(scope), "intake-key-#{key.id}")

    assert suggestion["intake_api_key_id"] == key.id
    assert suggestion["match_on"] == "intake_key"
  end

  test "suggests a top of rack rule until there is one", %{scope: scope, site: site} do
    {:ok, rack} = DCIM.create_rack(scope, %{name: "R12"}, %{site_id: site.id})
    switch = resource_fixture(scope, "switch", "leaf-01")
    {:ok, _placement} = DCIM.put_current_placement(scope, switch.id, %{rack_id: rack.id})

    for name <- ["web-01", "web-02"] do
      scope |> server_fixture(name) |> then(&lldp_fixture(scope, &1, switch))
    end

    assert %{count: 2, suggestion: %{"kind" => "top_of_rack"} = suggestion} =
             find(Patterns.list(scope), "top-of-rack")

    {:ok, %{rule: rule}} = TriageRules.create_rule(scope, suggestion)
    {:ok, _off} = TriageRules.set_enabled(scope, rule, false)
    refute find(Patterns.list(scope), "top-of-rack")
  end

  test "groups unowned resources by hostname prefix and label", %{scope: scope, team: team} do
    server_fixture(scope, "web-01", hostname: "web-01.dc1")
    server_fixture(scope, "web-02", hostname: "web-02.dc1")
    owned = server_fixture(scope, "web-03", hostname: "web-03.dc1")
    server_fixture(scope, "x1", hostname: "x1")
    {:ok, _owned} = Teams.set_owner(scope, owned, team.id)

    report_fixture(scope, "m-1", labels: %{"team" => "storage", "env" => "prod"})
    report_fixture(scope, "m-2", labels: %{"team" => "storage"})

    patterns = Patterns.list(scope, fact: :owner)

    assert %{count: 2, examples: ["web-01", "web-02"], suggestion: suggestion} =
             find(patterns, "hostname-web-")

    assert %{"kind" => "ownership", "hostname_pattern" => "web-*"} = suggestion

    assert %{count: 2, suggestion: %{"label_key" => "team", "label_value" => "storage"}} =
             find(patterns, "label-team=storage")

    refute find(patterns, "label-env=prod")
    assert Enum.all?(patterns, &(&1.fact == :owner))
    assert patterns == Enum.sort_by(patterns, &{-&1.count, &1.label})
  end

  defp find(patterns, id), do: Enum.find(patterns, &(&1.id == id))
end
