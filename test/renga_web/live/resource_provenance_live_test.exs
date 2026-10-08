defmodule RengaWeb.ResourceProvenanceLiveTest do
  use RengaWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Renga.AccountsFixtures
  import Renga.InventoryFixtures

  alias Renga.Inventory

  setup %{conn: conn} do
    user = user_fixture()
    organization = organization_fixture()
    organization_membership_fixture(user, organization, %{role: "admin"})
    scope = Renga.Accounts.scope_for_user(user, organization.id)

    {:ok, agent} = Inventory.create_source(scope, %{kind: "host_agent", name: "rack-agent"})
    {:ok, bmc} = Inventory.create_source(scope, %{kind: "bmc", name: "rack-bmc"})

    resource = report(scope, agent, 1, %{"hostname" => "web-01", "vendor" => "Agent Vendor"})
    report(scope, bmc, 2, %{"vendor" => "Dell", "model" => "R750"})

    {:ok, resource} =
      Inventory.update_resource(scope, resource, %{spec: %{"host" => %{"model" => "R760"}}})

    conn =
      conn
      |> log_in_user(user)
      |> put_session(:current_organization_id, organization.id)

    %{
      conn: conn,
      organization: organization,
      scope: scope,
      resource: resource,
      agent: agent,
      bmc: bmc
    }
  end

  test "each host value opens what every source reported and why one won", %{
    conn: conn,
    resource: resource,
    agent: agent,
    bmc: bmc
  } do
    {:ok, view, _html} = live(conn, ~p"/inventory/#{resource}")

    assert has_element?(view, "#property-vendor", "Dell")
    assert has_element?(view, "#provenance-vendor-value", "Dell")

    assert has_element?(
             view,
             "#provenance-vendor-source-#{bmc.id}[data-winner=true]",
             "management controller"
           )

    assert has_element?(
             view,
             "#provenance-vendor-source-#{agent.id}[data-winner=false]",
             "Agent Vendor"
           )

    assert has_element?(view, "#provenance-vendor-reason", "Management controllers")
    assert has_element?(view, "#provenance-asset_tag-sources", "No source reports this field.")
  end

  test "drift sits on the value itself", %{conn: conn, resource: resource} do
    {:ok, view, _html} = live(conn, ~p"/inventory/#{resource}")

    assert has_element?(view, "#property-model[data-drift=true]", "expected R760")
    assert has_element?(view, "#provenance-model-expected", "R760")
    assert has_element?(view, "#property-vendor[data-drift=false]")
    refute has_element?(view, "#provenance-vendor-expected")
  end

  test "managers override a value and hand it back to its sources", %{
    conn: conn,
    scope: scope,
    resource: resource,
    bmc: bmc
  } do
    {:ok, view, _html} = live(conn, ~p"/inventory/#{resource}")
    refute has_element?(view, "#override-model-clear")

    view
    |> form("#override-model-form", override: %{value: "R760", reason: "Swapped chassis"})
    |> render_submit()

    assert has_element?(view, "#property-model[data-drift=false]", "R760")
    assert has_element?(view, "#provenance-model-override", "Swapped chassis")
    assert has_element?(view, "#provenance-model-reason", "Overrides set by people")
    assert has_element?(view, "#provenance-model-source-#{bmc.id}[data-winner=false]")

    view |> element("#override-model-clear") |> render_click()

    assert has_element?(view, "#property-model[data-drift=true]", "R750")
    assert has_element?(view, "#provenance-model-source-#{bmc.id}[data-winner=true]")
    refute has_element?(view, "#override-model-clear")
    assert Inventory.list_resource_overrides(scope, resource.id) == []
  end

  test "a blank override shows the error in the panel", %{conn: conn, resource: resource} do
    {:ok, view, _html} = live(conn, ~p"/inventory/#{resource}")

    view
    |> form("#override-vendor-form", override: %{value: " "})
    |> render_submit()

    assert has_element?(view, "#override-vendor-form", "can't be blank")
    assert has_element?(view, "#property-vendor", "Dell")
  end

  test "members see provenance but not the override form", %{
    organization: organization,
    resource: resource
  } do
    member = user_fixture()
    organization_membership_fixture(member, organization, %{role: "member"})

    conn =
      build_conn()
      |> log_in_user(member)
      |> put_session(:current_organization_id, organization.id)

    {:ok, view, _html} = live(conn, ~p"/inventory/#{resource}")

    assert has_element?(view, "#provenance-vendor-reason")
    refute has_element?(view, "#override-vendor-form")
    assert has_element?(view, "#override-vendor-unavailable", "owner or admin")

    assert render_submit(view, "set_override", %{
             "field" => "vendor",
             "override" => %{"value" => "Forged"}
           }) =~ "Overrides require the owner or admin role"

    assert has_element?(view, "#property-vendor", "Dell")
  end

  defp report(scope, source, second, attributes) do
    observed_at = DateTime.add(~U[2026-08-01 12:00:00.000Z], second, :second)
    key = "#{source.id}-#{second}"

    {:ok, observation} =
      Inventory.create_observation(scope, source.id, %{
        idempotency_key: key,
        observed_at: observed_at,
        payload: %{
          "observation_id" => key,
          "observed_at" => DateTime.to_iso8601(observed_at),
          "resources" => [
            %{
              "kind" => "server",
              "identifiers" => %{"machine_id" => "machine-1"},
              "attributes" => attributes
            }
          ]
        }
      })

    {:ok, resource, _created?} = Inventory.reconcile_observation(scope, observation.id)
    resource
  end
end
