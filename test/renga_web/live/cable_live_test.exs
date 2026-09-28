defmodule RengaWeb.CableLiveTest do
  use RengaWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Renga.AccountsFixtures
  import Renga.InventoryFixtures

  alias Renga.Accounts
  alias Renga.Inventory
  alias Renga.Topology

  setup %{conn: conn} do
    user = user_fixture()
    organization = organization_fixture()
    organization_membership_fixture(user, organization, %{role: "admin"})
    scope = Accounts.scope_for_user(user, organization.id)

    conn =
      conn
      |> log_in_user(user)
      |> put_session(:current_organization_id, organization.id)

    %{conn: conn, organization: organization, scope: scope}
  end

  test "shows current cables, plans, and claims as separate sections", %{conn: conn, scope: scope} do
    {first, second, third} = cable_interfaces(scope)

    {:ok, assertion} =
      Topology.assert_cable(scope, %{
        interface_a_id: first.id,
        interface_b_id: second.id,
        cable_type: "cat6a",
        label: "uplink"
      })

    [cable] = Topology.list_cables(scope)

    {:ok, plan} =
      Topology.put_cable_plan(scope, %{
        interface_a_id: first.id,
        interface_b_id: third.id,
        cable_type: "dac"
      })

    {:ok, view, _html} = live(conn, ~p"/network/cables")

    assert has_element?(view, "#current-cables")
    assert has_element?(view, "#cable-plans")
    assert has_element?(view, "#cable-claims")

    assert has_element?(view, "#cable-#{cable.id}[data-cable-type='cat6a']")
    assert has_element?(view, "#cable-#{cable.id}", "uplink")
    assert has_element?(view, "#cable-#{cable.id}", "connected")

    assert has_element?(view, "#plan-#{plan.id}[data-plan-status='planned']")
    assert has_element?(view, "#claim-#{assertion.id}[data-claim-kind='operator']")
    assert has_element?(view, "#claim-#{assertion.id}[data-claim-action='assert']")

    # Manager controls are offered, but the context remains the authorization boundary.
    assert has_element?(view, "#assert-cable-form")
    assert has_element?(view, "#plan-cable-form")
    assert has_element?(view, "#retract-cable-#{cable.id}")
    assert has_element?(view, "#delete-plan-#{plan.id}")
  end

  test "managers confirm and retract a cable from the UI", %{conn: conn, scope: scope} do
    {first, second, _third} = cable_interfaces(scope)

    {:ok, view, _html} = live(conn, ~p"/network/cables")

    view
    |> form("#assert-cable-form",
      cable: %{
        interface_a_id: first.id,
        interface_b_id: second.id,
        cable_type: "cat6a",
        label: "ui-uplink"
      }
    )
    |> render_submit()

    assert has_element?(view, "#flash-info", "Current cable confirmed")
    assert [cable] = Topology.list_cables(scope)
    assert has_element?(view, "#cable-#{cable.id}", "ui-uplink")

    view |> element("#retract-cable-#{cable.id}") |> render_click()

    assert has_element?(view, "#flash-info", "endpoints are released")
    assert Topology.list_cables(scope) == []
    refute has_element?(view, "#cable-#{cable.id}")
    assert [retraction, assertion] = Topology.list_cable_assertions(scope)
    assert retraction.action == "retract"
    assert assertion.action == "assert"
  end

  test "managers record and remove a plan from the UI", %{conn: conn, scope: scope} do
    {first, second, _third} = cable_interfaces(scope)

    {:ok, view, _html} = live(conn, ~p"/network/cables")

    view
    |> form("#plan-cable-form",
      plan: %{
        interface_a_id: first.id,
        interface_b_id: second.id,
        cable_type: "dac",
        label: "planned"
      }
    )
    |> render_submit()

    assert has_element?(view, "#flash-info", "Cable plan recorded")
    assert [plan] = Topology.list_cable_plans(scope)
    assert has_element?(view, "#plan-#{plan.id}", "planned")

    view |> element("#delete-plan-#{plan.id}") |> render_click()

    assert has_element?(view, "#flash-info", "Cable plan removed")
    assert Topology.list_cable_plans(scope) == []
  end

  test "members read cabling without manager controls", %{
    organization: organization,
    scope: scope
  } do
    {first, second, _third} = cable_interfaces(scope)

    {:ok, _assertion} =
      Topology.assert_cable(scope, %{interface_a_id: first.id, interface_b_id: second.id})

    [cable] = Topology.list_cables(scope)

    member = user_fixture()
    organization_membership_fixture(member, organization, %{role: "member"})

    member_conn =
      build_conn()
      |> log_in_user(member)
      |> put_session(:current_organization_id, organization.id)

    {:ok, view, _html} = live(member_conn, ~p"/network/cables")

    assert has_element?(view, "#cable-#{cable.id}")
    refute has_element?(view, "#assert-cable-form")
    refute has_element?(view, "#plan-cable-form")
    refute has_element?(view, "#retract-cable-#{cable.id}")
  end

  test "filters cables, plans, and claims by interface", %{conn: conn, scope: scope} do
    {first, second, third} = cable_interfaces(scope)

    {:ok, _assertion} =
      Topology.assert_cable(scope, %{interface_a_id: first.id, interface_b_id: second.id})

    [cable] = Topology.list_cables(scope)

    {:ok, other_plan} =
      Topology.put_cable_plan(scope, %{interface_a_id: second.id, interface_b_id: third.id})

    {:ok, view, _html} = live(conn, ~p"/network/cables?#{[interface_id: first.id]}")

    assert has_element?(view, "#cables-clear-interface")
    assert has_element?(view, "#cable-#{cable.id}")
    refute has_element?(view, "#plan-#{other_plan.id}")
  end

  test "requires authentication" do
    assert {:error, {:redirect, %{to: path}}} = live(build_conn(), ~p"/network/cables")
    assert path =~ "/users/log-in"
  end

  defp cable_interfaces(scope) do
    suffix = System.unique_integer([:positive])

    names = for index <- 1..3, do: "cable-ui-#{suffix}-#{index}"

    interfaces =
      Enum.map(names, fn name ->
        {:ok, resource} =
          Inventory.create_resource(scope, %{
            kind: "server",
            name: name,
            lifecycle_state: "active"
          })

        {:ok, interface} = Inventory.create_interface(scope, resource.id, %{name: "eth#{name}"})
        interface
      end)

    List.to_tuple(interfaces)
  end
end
