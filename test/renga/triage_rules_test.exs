defmodule Renga.TriageRulesTest do
  use Renga.DataCase, async: true

  import Renga.AccountsFixtures
  import Ecto.Query
  import Renga.InventoryFixtures
  import Renga.TriageFixtures

  alias Renga.Accounts
  alias Renga.DCIM
  alias Renga.DCIM.CurrentPlacement
  alias Renga.Inventory
  alias Renga.Inventory.ChangeEvent
  alias Renga.Repo
  alias Renga.Teams
  alias Renga.TriageRules

  setup do
    organization = organization_fixture()
    admin = user_fixture()
    organization_membership_fixture(admin, organization, %{role: "admin"})
    scope = Accounts.scope_for_user(admin, organization.id)

    {:ok, site} = DCIM.create_site(scope, %{name: "DC1"}, %{slug: "dc1"})
    {:ok, rack} = DCIM.create_rack(scope, %{name: "R12"}, %{site_id: site.id, height_units: 42})
    {:ok, team} = Teams.create_team(scope, %{"name" => "Platform"})

    %{organization: organization, scope: scope, site: site, rack: rack, team: team}
  end

  describe "network location" do
    test "puts resources reporting from a subnet at the site, unconfirmed", context do
      %{scope: scope, site: site} = context
      unplaced = server_fixture(scope, "web-01", address: "10.20.3.44/24")
      elsewhere = server_fixture(scope, "web-02", address: "10.99.0.5/24")
      confirmed = server_fixture(scope, "web-03", address: "10.20.3.45/24")

      {:ok, _placement} =
        DCIM.put_current_placement(scope, confirmed.id, %{site_id: site.id, confirmed: true})

      attrs = %{
        "kind" => "network_location",
        "name" => "DC1 servers",
        "match_on" => "subnet",
        "subnet" => "10.20.0.0/16",
        "site_id" => site.id
      }

      assert {:ok, preview} = TriageRules.preview(scope, attrs)
      assert %{will_set: 1, has_value: 0, set_by_person: 1} = preview
      assert [%{name: "web-01"}] = preview.examples

      assert {:ok, %{rule: rule, applied: 1}} = TriageRules.create_rule(scope, attrs)

      placement = placement(scope, unplaced)
      assert placement.site_id == site.id
      assert placement.rack_id == nil
      refute placement.confirmed
      assert placement.provenance["rule_id"] == rule.id
      assert placement.provenance["rule_name"] == "DC1 servers"

      assert placement(scope, elsewhere) == nil
      assert placement(scope, confirmed).confirmed

      assert [event] = events(scope, unplaced, "rule_applied")
      assert event.field == "placement"
      assert event.new_value["value"] == "DC1"
      assert event.metadata["rule_id"] == rule.id
      assert event.actor_user_id == scope.user.id
    end

    test "places new discoveries as collectors report them", %{scope: scope, site: site} do
      {:ok, {key, _token}} = Inventory.create_intake_api_key(scope, %{name: "DC1 fleet"})

      {:ok, %{rule: _rule}} =
        TriageRules.create_rule(scope, %{
          "kind" => "network_location",
          "name" => "DC1 fleet",
          "match_on" => "intake_key",
          "intake_api_key_id" => key.id,
          "site_id" => site.id
        })

      resource = report_fixture(scope, "m-1", intake_api_key_id: key.id)

      assert %{site_id: site_id, confirmed: false} = placement(scope, resource)
      assert site_id == site.id
      assert [%{actor_user_id: nil}] = events(scope, resource, "rule_applied")

      other = report_fixture(scope, "m-2", reported_from: {10, 1, 1, 1})
      assert placement(scope, other) == nil
    end

    test "matches the address a collector reports from", %{scope: scope, site: site} do
      {:ok, _result} =
        TriageRules.create_rule(scope, %{
          "kind" => "network_location",
          "name" => "Lab",
          "match_on" => "subnet",
          "subnet" => "192.0.2.0/28",
          "site_id" => site.id
        })

      inside = report_fixture(scope, "m-1", reported_from: {192, 0, 2, 9})
      outside = report_fixture(scope, "m-2", reported_from: {192, 0, 2, 99})

      assert placement(scope, inside).site_id == site.id
      assert placement(scope, outside) == nil
    end

    test "requires one condition with a prefix and a location at the site", context do
      %{scope: scope, site: site} = context
      {:ok, other_site} = DCIM.create_site(scope, %{name: "DC2"}, %{slug: "dc2"})
      {:ok, hall} = DCIM.create_location(scope, %{name: "Hall B"}, %{site_id: other_site.id})

      base = %{"kind" => "network_location", "name" => "Rule", "site_id" => site.id}

      assert {:error, changeset} = TriageRules.preview(scope, Map.put(base, "subnet", "10.0.0.1"))
      assert %{subnet: ["needs a prefix length, such as /24"]} = errors_on(changeset)

      assert {:error, changeset} = TriageRules.preview(scope, base)
      assert %{subnet: [_]} = errors_on(changeset)

      assert {:error, changeset} =
               TriageRules.create_rule(
                 scope,
                 Map.merge(base, %{"subnet" => "10.0.0.0/8", "location_id" => hall.id})
               )

      assert %{location_id: ["is not at that site"]} = errors_on(changeset)
    end
  end

  describe "top of rack" do
    test "puts servers in their LLDP neighbor switch's rack, never at a unit", context do
      %{scope: scope, rack: rack} = context
      server = server_fixture(scope, "web-01")
      switch = resource_fixture(scope, "switch", "leaf-01")
      {:ok, _placement} = DCIM.put_current_placement(scope, switch.id, %{rack_id: rack.id})
      lldp_fixture(scope, server, switch)

      # A switch seen from another switch is an uplink, not its rack.
      spine = resource_fixture(scope, "switch", "spine-01")
      lldp_fixture(scope, spine, switch, "uplink")

      attrs = %{"kind" => "top_of_rack", "name" => "Top of rack"}

      assert {:ok, %{will_set: 1, examples: [%{name: "web-01"}]}} =
               TriageRules.preview(scope, attrs)

      assert {:ok, %{applied: 1}} = TriageRules.create_rule(scope, attrs)

      placement = placement(scope, server)
      assert placement.rack_id == rack.id
      assert placement.site_id == rack.site_id
      assert placement.position == nil
      refute placement.confirmed

      assert placement(scope, spine) == nil
    end

    test "leaves resources whose neighbors sit in different racks", context do
      %{scope: scope, rack: rack, site: site} = context
      {:ok, other_rack} = DCIM.create_rack(scope, %{name: "R13"}, %{site_id: site.id})
      server = server_fixture(scope, "web-01")

      for {name, rack} <- [{"leaf-01", rack}, {"leaf-02", other_rack}] do
        switch = resource_fixture(scope, "switch", name)
        {:ok, _placement} = DCIM.put_current_placement(scope, switch.id, %{rack_id: rack.id})
        lldp_fixture(scope, server, switch, "eth-#{name}")
      end

      assert {:ok, %{applied: 0}} =
               TriageRules.create_rule(scope, %{"kind" => "top_of_rack", "name" => "ToR"})

      assert placement(scope, server) == nil
    end
  end

  describe "ownership" do
    test "a hostname pattern owns matching resources without replacing a person's choice",
         context do
      %{scope: scope, team: team} = context
      {:ok, storage} = Teams.create_team(scope, %{"name" => "Storage"})
      web = server_fixture(scope, "web-01", hostname: "web-01.dc1")
      chosen = server_fixture(scope, "web-02", hostname: "web-02.dc1")
      underscore = server_fixture(scope, "db_1", hostname: "db_1")
      lookalike = server_fixture(scope, "dbx1", hostname: "dbx1")
      {:ok, _chosen} = Teams.set_owner(scope, chosen, storage.id)

      attrs = %{
        "kind" => "ownership",
        "name" => "Web",
        "hostname_pattern" => "WEB-*",
        "team_id" => team.id
      }

      assert {:ok, %{will_set: 1, set_by_person: 1}} = TriageRules.preview(scope, attrs)
      assert {:ok, %{rule: rule, applied: 1}} = TriageRules.create_rule(scope, attrs)
      assert rule.hostname_pattern == "web-*"

      web = Repo.reload!(web)
      assert web.owner_team_id == team.id
      assert web.owner_source == "rule"
      assert web.owner_rule_id == rule.id
      assert Repo.reload!(chosen).owner_team_id == storage.id

      assert [%{field: "owner_team", new_value: %{"name" => "Platform"}}] =
               events(scope, web, "rule_applied")

      assert {:ok, %{applied: 1}} =
               TriageRules.create_rule(scope, %{
                 "kind" => "ownership",
                 "name" => "Databases",
                 "hostname_pattern" => "db_1",
                 "team_id" => storage.id
               })

      assert Repo.reload!(underscore).owner_team_id == storage.id
      assert Repo.reload!(lookalike).owner_team_id == nil
    end

    test "a collector label owns resources as they report", %{scope: scope, team: team} do
      {:ok, _result} =
        TriageRules.create_rule(scope, %{
          "kind" => "ownership",
          "name" => "Platform label",
          "label_key" => "team",
          "label_value" => "platform",
          "team_id" => team.id
        })

      labelled = report_fixture(scope, "m-1", labels: %{"team" => "platform"})
      other = report_fixture(scope, "m-2", labels: %{"team" => "storage"})

      assert %{owner_team_id: team_id, owner_source: "rule"} = Repo.reload!(labelled)
      assert team_id == team.id
      assert Repo.reload!(other).owner_team_id == nil
    end

    test "a person setting the owner takes it over from the rule", context do
      %{scope: scope, team: team} = context
      web = server_fixture(scope, "web-01", hostname: "web-01")

      {:ok, %{rule: _rule}} =
        TriageRules.create_rule(scope, %{
          "kind" => "ownership",
          "name" => "Web",
          "hostname_pattern" => "web-*",
          "team_id" => team.id
        })

      {:ok, web} = Teams.set_owner(scope, Repo.reload!(web), team.id)
      assert %{owner_source: "person", owner_rule_id: nil} = web
    end

    test "needs exactly one condition and a team from this organization", context do
      %{scope: scope} = context
      foreign_scope = admin_scope()
      {:ok, foreign_team} = Teams.create_team(foreign_scope, %{"name" => "Elsewhere"})

      base = %{"kind" => "ownership", "name" => "Rule"}

      assert {:error, changeset} = TriageRules.preview(scope, base)
      assert %{hostname_pattern: [_], team_id: [_]} = errors_on(changeset)

      assert {:error, changeset} =
               TriageRules.preview(
                 scope,
                 Map.merge(base, %{"hostname_pattern" => "web-%", "team_id" => context.team.id})
               )

      assert %{hostname_pattern: [_]} = errors_on(changeset)

      assert {:error, changeset} =
               TriageRules.preview(
                 scope,
                 Map.merge(base, %{"label_key" => "team", "team_id" => context.team.id})
               )

      assert %{label_value: [_]} = errors_on(changeset)

      assert {:error, changeset} =
               TriageRules.create_rule(
                 scope,
                 Map.merge(base, %{"hostname_pattern" => "web-*", "team_id" => foreign_team.id})
               )

      assert %{team_id: ["is not in this organization"]} = errors_on(changeset)
    end
  end

  describe "managing rules" do
    test "only owners and admins manage rules", %{organization: organization, team: team} do
      member = user_fixture()
      organization_membership_fixture(member, organization, %{role: "member"})
      member_scope = Accounts.scope_for_user(member, organization.id)

      refute TriageRules.can_manage?(member_scope)

      assert {:error, :forbidden} =
               TriageRules.create_rule(member_scope, %{
                 "kind" => "ownership",
                 "name" => "Web",
                 "hostname_pattern" => "web-*",
                 "team_id" => team.id
               })
    end

    test "a disabled rule stops applying and a deleted rule keeps what it set", context do
      %{scope: scope, team: team} = context

      {:ok, %{rule: rule}} =
        TriageRules.create_rule(scope, %{
          "kind" => "ownership",
          "name" => "Platform label",
          "label_key" => "team",
          "label_value" => "platform",
          "team_id" => team.id
        })

      first = report_fixture(scope, "m-1", labels: %{"team" => "platform"})
      assert Repo.reload!(first).owner_rule_id == rule.id

      assert {:ok, %{rule: %{enabled: false}}} = TriageRules.set_enabled(scope, rule, false)
      second = report_fixture(scope, "m-2", labels: %{"team" => "platform"})
      assert Repo.reload!(second).owner_team_id == nil

      assert {:ok, %{applied: 1}} = TriageRules.set_enabled(scope, rule, true)
      assert Repo.reload!(second).owner_team_id == team.id

      assert {:ok, _deleted} = TriageRules.delete_rule(scope, rule)

      assert %{owner_team_id: team_id, owner_source: "rule", owner_rule_id: nil} =
               Repo.reload!(first)

      assert team_id == team.id
      assert TriageRules.list_rules(scope) == []
    end
  end

  defp admin_scope do
    organization = organization_fixture()
    user = user_fixture()
    organization_membership_fixture(user, organization, %{role: "admin"})
    Accounts.scope_for_user(user, organization.id)
  end

  defp placement(scope, resource) do
    Repo.get_by(CurrentPlacement,
      organization_id: scope.organization_id,
      resource_id: resource.id
    )
  end

  defp events(scope, resource, kind) do
    ChangeEvent
    |> where([event], event.organization_id == ^scope.organization_id)
    |> where([event], event.resource_id == ^resource.id and event.kind == ^kind)
    |> Repo.all()
  end
end
