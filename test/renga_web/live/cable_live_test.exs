defmodule RengaWeb.CableLiveTest do
  use RengaWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Renga.AccountsFixtures
  import Renga.InventoryFixtures

  alias Renga.Accounts
  alias Renga.Inventory
  alias Renga.Repo
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

  test "reports missing plan endpoints instead of crashing the form", %{conn: conn, scope: scope} do
    {first, second, _third} = cable_interfaces(scope)

    {:ok, view, _html} = live(conn, ~p"/network/cables")

    for plan <- [
          %{interface_a_id: first.id, interface_b_id: "", cable_type: "", label: ""},
          %{interface_a_id: "", interface_b_id: second.id, cable_type: "", label: ""},
          %{interface_a_id: "", interface_b_id: "", cable_type: "", label: ""}
        ] do
      view
      |> form("#plan-cable-form", plan: plan)
      |> render_submit()

      assert has_element?(view, "#flash-error", "Select both cable endpoints")
      assert Topology.list_cable_plans(scope) == []
    end

    # The same view still completes a valid plan after the errors.
    view
    |> form("#plan-cable-form",
      plan: %{
        interface_a_id: first.id,
        interface_b_id: second.id,
        cable_type: "cat6a",
        label: "after-error"
      }
    )
    |> render_submit()

    assert has_element?(view, "#flash-info", "Cable plan recorded")
    assert [plan] = Topology.list_cable_plans(scope)
    assert first.id in [plan.interface_a_id, plan.interface_b_id]

    # Confirming with a missing endpoint is a changeset error, not a crash.
    view
    |> form("#assert-cable-form",
      cable: %{interface_a_id: first.id, interface_b_id: "", cable_type: "", label: ""}
    )
    |> render_submit()

    assert has_element?(view, "#flash-error", "can't be blank")
    assert Topology.list_cables(scope) == []
  end

  test "a manager downgraded after mount cannot confirm cabling", %{
    conn: conn,
    organization: organization,
    scope: scope
  } do
    {first, second, _third} = cable_interfaces(scope)
    {:ok, view, _html} = live(conn, ~p"/network/cables")

    assert has_element?(view, "#assert-cable-form")

    membership =
      Repo.get_by!(Renga.Accounts.OrganizationMembership,
        user_id: scope.user.id,
        organization_id: organization.id
      )

    {:ok, _membership} =
      Renga.Accounts.update_organization_membership(membership, %{role: "member"})

    view
    |> form("#assert-cable-form",
      cable: %{interface_a_id: first.id, interface_b_id: second.id, cable_type: "", label: ""}
    )
    |> render_submit()

    assert has_element?(view, "#flash-error", "not allowed")
    assert Topology.list_cables(scope) == []
    assert Topology.list_cable_assertions(scope) == []
  end

  test "keeps another organization's cabling invisible", %{conn: conn, scope: scope} do
    {first, second, _third} = cable_interfaces(scope)

    {:ok, _assertion} =
      Topology.assert_cable(scope, %{interface_a_id: first.id, interface_b_id: second.id})

    [local_cable] = Topology.list_cables(scope)

    foreign_user = user_fixture()
    foreign_organization = organization_fixture()
    organization_membership_fixture(foreign_user, foreign_organization, %{role: "admin"})
    foreign_scope = Accounts.scope_for_user(foreign_user, foreign_organization.id)

    {foreign_first, foreign_second, _third} = cable_interfaces(foreign_scope)

    {:ok, _assertion} =
      Topology.assert_cable(foreign_scope, %{
        interface_a_id: foreign_first.id,
        interface_b_id: foreign_second.id
      })

    [foreign_cable] = Topology.list_cables(foreign_scope)

    {:ok, foreign_plan} =
      Topology.put_cable_plan(foreign_scope, %{
        interface_a_id: foreign_first.id,
        interface_b_id: foreign_second.id
      })

    {:ok, view, _html} = live(conn, ~p"/network/cables")

    assert has_element?(view, "#cable-#{local_cable.id}")
    refute has_element?(view, "#cable-#{foreign_cable.id}")
    refute has_element?(view, "#plan-#{foreign_plan.id}")

    refute has_element?(
             view,
             "#assert-cable-form option[value='#{foreign_first.id}']"
           )
  end

  test "tracks cable form values and resets them after success", %{conn: conn, scope: scope} do
    {first, second, _third} = cable_interfaces(scope)
    {:ok, view, _html} = live(conn, ~p"/network/cables")

    view
    |> form("#assert-cable-form",
      cable: %{
        interface_a_id: first.id,
        interface_b_id: second.id,
        cable_type: "cat6a",
        label: "typed"
      }
    )
    |> render_change()

    assert has_element?(view, "#assert-cable-form input[name='cable[label]'][value='typed']")

    # A failed submission keeps the entered values for correction.
    view
    |> form("#assert-cable-form",
      cable: %{
        interface_a_id: first.id,
        interface_b_id: first.id,
        cable_type: "cat6a",
        label: "typed"
      }
    )
    |> render_submit()

    assert has_element?(view, "#flash-error", "distinct endpoints")
    assert has_element?(view, "#assert-cable-form input[name='cable[label]'][value='typed']")

    # A successful submission resets the form to its defaults.
    view
    |> form("#assert-cable-form",
      cable: %{
        interface_a_id: first.id,
        interface_b_id: second.id,
        cable_type: "cat6a",
        label: "typed"
      }
    )
    |> render_submit()

    assert has_element?(view, "#flash-info", "Current cable confirmed")
    assert has_element?(view, "#assert-cable-form input[name='cable[label]'][value='']")
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
