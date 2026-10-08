defmodule RengaWeb.ResourceSignalsLiveTest do
  use RengaWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Renga.AccountsFixtures
  import Renga.InventoryFixtures

  alias Renga.Inventory

  test "the Sources tab shows how each collector reports the resource", %{conn: conn} do
    organization = organization_fixture()
    user = user_fixture()
    organization_membership_fixture(user, organization, %{role: "admin"})
    scope = Renga.Accounts.scope_for_user(user, organization.id)
    {:ok, source} = Inventory.create_source(scope, %{kind: "host_agent", name: "rack-agent"})

    {:ok, observation} =
      Inventory.create_observation(scope, source.id, %{
        idempotency_key: "report-1",
        observed_at: DateTime.utc_now(),
        reported_from: %Postgrex.INET{address: {10, 20, 3, 44}, netmask: nil},
        payload: %{
          "resources" => [
            %{
              "kind" => "server",
              "identifiers" => %{"machine_id" => "m-1"},
              "attributes" => %{"hostname" => "web-01"},
              "labels" => %{"team" => "storage"}
            }
          ]
        }
      })

    {:ok, resource, _created?} = Inventory.reconcile_observation(scope, observation.id)

    {:ok, view, _html} =
      conn
      |> log_in_user(user)
      |> put_session(:current_organization_id, organization.id)
      |> live(~p"/inventory/#{resource}/sources")

    assert has_element?(view, "#signal-#{source.id}", "rack-agent")
    assert has_element?(view, "#signal-#{source.id}", "10.20.3.44")
    assert has_element?(view, "#signal-#{source.id} [data-label=team]", "team=storage")
  end
end
