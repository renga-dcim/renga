defmodule RengaWeb.Browser.CablesTest do
  @moduledoc """
  Cable endpoints at phone width: long interface and resource identities stay
  available through the overflow tooltip, and the endpoint remains a link to
  its resource.
  """
  use PhoenixTest.Playwright.Case, async: true

  import Renga.AccountsFixtures
  import Renga.InventoryFixtures

  alias Renga.Inventory
  alias Renga.Topology

  @moduletag :playwright
  @moduletag browser_context_opts: [
               has_touch: true,
               is_mobile: true,
               viewport: %{width: 390, height: 844}
             ]

  @tooltip """
  new Promise(resolve => setTimeout(() => {
    const tooltip = document.getElementById("clip-tooltip")
    resolve(tooltip?.matches(":popover-open") ? tooltip.textContent : null)
  }, 600))
  """

  setup %{conn: conn} do
    organization = organization_fixture()
    user = user_fixture()
    organization_membership_fixture(user, organization, %{role: "admin"})
    scope = Renga.Accounts.scope_for_user(user, organization.id)

    {first_resource, first} =
      interface_fixture(
        scope,
        "core-distribution-switch-building-a-floor-twenty-two",
        "forty-gigabit-ethernet-0/0/48"
      )

    {_second_resource, second} =
      interface_fixture(scope, "aggregation-switch-building-b", "forty-gigabit-ethernet-0/0/47")

    {third_resource, third} =
      interface_fixture(scope, "access-switch-building-c", "gigabit-ethernet-0/0/1")

    {:ok, _assertion} =
      Topology.assert_cable(scope, %{
        interface_a_id: first.id,
        interface_b_id: second.id,
        cable_type: "fiber",
        status: "decommissioning"
      })

    [cable] = Topology.list_cables(scope)

    {_short_resource, short_first} = interface_fixture(scope, "a", "b")
    {_short_second_resource, short_second} = interface_fixture(scope, "c", "d")

    {:ok, _assertion} =
      Topology.assert_cable(scope, %{
        interface_a_id: short_first.id,
        interface_b_id: short_second.id
      })

    short_cable = Enum.find(Topology.list_cables(scope), &(&1.id != cable.id))

    {:ok, plan} =
      Topology.put_cable_plan(scope, %{
        interface_a_id: first.id,
        interface_b_id: third.id,
        status: "connected"
      })

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

    %{
      conn: conn,
      cable: cable,
      first: first,
      first_resource: first_resource,
      plan: plan,
      scope: scope,
      short_cable: short_cable,
      short_first: short_first,
      third: third,
      third_resource: third_resource
    }
  end

  test "a clipped endpoint reveals its full identity and keeps resource navigation", context do
    endpoint_side =
      if context.cable.interface_a.id == context.first.id, do: "first", else: "second"

    short_endpoint_side =
      if context.short_cable.interface_a.id == context.short_first.id, do: "first", else: "second"

    endpoint = "#cable-#{context.cable.id}-#{endpoint_side}-endpoint"
    short_endpoint = "#cable-#{context.short_cable.id}-#{short_endpoint_side}-endpoint"

    session =
      context.conn
      |> visit("/network/cables")
      |> assert_has("body .phx-connected")
      |> evaluate(
        "document.querySelector(#{Jason.encode!(endpoint)}).scrollWidth > document.querySelector(#{Jason.encode!(endpoint)}).clientWidth",
        &assert(&1 == true)
      )
      |> evaluate(
        "new Promise(resolve => setTimeout(() => resolve(document.querySelector(#{Jason.encode!(endpoint)}).tabIndex), 500))",
        &assert(&1 == 0)
      )
      |> evaluate(
        """
        (() => {
          const el = document.querySelector(#{Jason.encode!(short_endpoint)})
          return {fits: el.scrollWidth === el.clientWidth, tab_index: el.tabIndex}
        })()
        """,
        &assert(&1 == %{"fits" => true, "tab_index" => 0})
      )
      |> evaluate(
        """
        new Promise(resolve => {
          const el = document.querySelector(#{Jason.encode!(short_endpoint)})
          el.style.width = '1px'
          el.style.maxWidth = '1px'
          requestAnimationFrame(() => requestAnimationFrame(() => resolve({clipped: el.scrollWidth > el.clientWidth, tab_index: el.tabIndex})))
        })
        """,
        &assert(&1 == %{"clipped" => true, "tab_index" => 0})
      )
      |> evaluate(
        """
        new Promise(resolve => {
          const el = document.querySelector(#{Jason.encode!(short_endpoint)})
          el.style.width = ''
          el.style.maxWidth = ''
          requestAnimationFrame(() => requestAnimationFrame(() => resolve({fits: el.scrollWidth === el.clientWidth, tab_index: el.tabIndex})))
        })
        """,
        &assert(&1 == %{"fits" => true, "tab_index" => 0})
      )
      |> hover(endpoint)
      |> evaluate(
        @tooltip,
        &assert(
          &1 =~
            "forty-gigabit-ethernet-0/0/48 · core-distribution-switch-building-a-floor-twenty-two"
        )
      )
      |> tab_until(endpoint)
      |> assert_has("#{endpoint}:focus")
      |> evaluate(@tooltip, &assert(&1 =~ "forty-gigabit-ethernet-0/0/48"))
      |> press(":focus", "Escape")
      |> touch(endpoint)
      |> evaluate(@tooltip, &assert(&1 =~ "core-distribution-switch-building-a-floor-twenty-two"))
      |> dispatch_click(endpoint)
      |> assert_path("/network/cables")
      |> assert_has("#{endpoint}:focus")
      |> evaluate(
        """
        (() => {
          const link = document.querySelector(#{Jason.encode!(endpoint)})
          return {clipped_ancestor: Boolean(link.parentElement.closest('[data-clip]')), ring: getComputedStyle(link).boxShadow}
        })()
        """,
        &assert(&1["clipped_ancestor"] == false && &1["ring"] != "none")
      )
      |> evaluate("window.__cableLiveNavigation = 'kept'")

    session
    |> touch(endpoint)
    |> click(endpoint)
    |> assert_path("/inventory/#{context.first_resource.id}")
    |> assert_has("body .phx-connected")
    |> evaluate("window.__cableLiveNavigation", &assert(&1 == "kept"))
  end

  test "cable forms use panels and destructive actions use dialogs", context do
    first_option = "#{context.first_resource.name} / #{context.first.name}"
    third_option = "#{context.third_resource.name} / #{context.third.name}"
    label_input = "#plan-cable-form input[name='plan[label]']"

    session =
      context.conn
      |> visit("/network/cables")
      |> assert_has("body .phx-connected")
      |> assert_has(
        "#cable-#{context.cable.id}-compact-status[aria-label='Status: decommissioning']"
      )
      |> assert_has("#plan-#{context.plan.id}-compact-status[aria-label='Status: connected']")
      |> assert_minimum_tap_target("#cable-#{context.cable.id}-compact-status")
      |> assert_minimum_tap_target("#plan-#{context.plan.id}-compact-status")
      |> assert_table_contained("#cables-list")
      |> assert_table_contained("#plans-list")
      |> touch("#cable-#{context.cable.id}-compact-status")
      |> evaluate(@tooltip, &assert(&1 =~ "decommissioning"))
      |> press(":focus", "Escape")
      |> touch("#plan-#{context.plan.id}-compact-status")
      |> evaluate(@tooltip, &assert(&1 =~ "connected"))
      |> press(":focus", "Escape")
      |> click("#new-current-cable")
      |> assert_has("#assert-cable-panel [role=dialog]", text: "Confirm current cable")
      |> press("#assert-cable-panel [role=dialog]", "Escape")
      |> refute_has("#assert-cable-panel [role=dialog]")
      |> assert_has("#new-current-cable:focus")
      |> click("#new-cable-plan")
      |> assert_has("#plan-cable-panel [role=dialog]", text: "Plan desired cable")
      |> click("#plan-cable")
      |> assert_has("#flash-error", text: "Select both cable endpoints")
      |> assert_has("#plan-cable-panel [role=dialog]")
      |> select_option("#plan_interface_a_id", first_option)
      |> select_option("#plan_interface_b_id", third_option)
      |> click(label_input)
      |> press(":focus", "b")
      |> assert_has("#{label_input}:focus[value='b']")
      |> press(":focus", "r")
      |> press(":focus", "o")
      |> press(":focus", "w")
      |> press(":focus", "s")
      |> press(":focus", "e")
      |> press(":focus", "r")
      |> assert_has("#{label_input}:focus")
      |> press(":focus", "End")
      |> press(":focus", "-")
      |> press(":focus", "p")
      |> assert_has("#{label_input}:focus[value='browser-p']")
      |> fill_in(label_input, "Label (optional)", with: "browser-plan")
      |> click("#plan-cable")
      |> assert_has("#flash-info", text: "Cable plan recorded")
      |> refute_has("#plan-cable-panel [role=dialog]")
      |> assert_table_contained("#plans-list")

    [plan] = Topology.list_cable_plans(context.scope)

    session
    |> assert_has("#plan-#{plan.id}")
    |> click("#delete-plan-#{plan.id}")
    |> assert_has("#delete-plan-#{plan.id}-dialog [role=alertdialog]")
    |> click("#delete-plan-#{plan.id}-dialog-cancel")
    |> refute_has("#delete-plan-#{plan.id}-dialog [role=alertdialog]")
    |> click("#retract-cable-#{context.cable.id}")
    |> assert_has("#retract-cable-#{context.cable.id}-dialog [role=alertdialog]")
  end

  defp hover(conn, selector) do
    unwrap(conn, fn %{frame_id: frame_id} ->
      assert {:ok, _} = PlaywrightEx.Frame.hover(frame_id, selector: selector, timeout: 2000)
    end)
  end

  defp touch(conn, selector) do
    unwrap(conn, fn %{frame_id: frame_id} ->
      for type <- ~w(pointerdown pointerup) do
        assert {:ok, _} =
                 PlaywrightEx.Frame.dispatch_event(frame_id,
                   selector: selector,
                   type: type,
                   event_init: %{pointerType: "touch", bubbles: true},
                   timeout: 2000
                 )
      end
    end)
  end

  defp dispatch_click(conn, selector) do
    unwrap(conn, fn %{frame_id: frame_id} ->
      assert {:ok, _} =
               PlaywrightEx.Frame.dispatch_event(frame_id,
                 selector: selector,
                 type: "click",
                 event_init: %{bubbles: true},
                 timeout: 2000
               )
    end)
  end

  defp assert_table_contained(session, body_selector) do
    evaluate(
      session,
      """
      (() => {
        const body = document.querySelector(#{Jason.encode!(body_selector)})
        const table = body.closest("table")
        const wrapper = table.parentElement
        const headers = [...table.querySelectorAll("thead th")].slice(0, 2)
        const actionCell = body.querySelector("tr[data-list-row] td:last-child")
        const action = actionCell.querySelector("button")
        const cellBounds = actionCell.getBoundingClientRect()
        const actionBounds = action.getBoundingClientRect()

        return {
          wrapper: wrapper.scrollWidth <= wrapper.clientWidth,
          headers: headers.every(header => header.scrollWidth <= header.clientWidth),
          action: actionBounds.left >= cellBounds.left && actionBounds.right <= cellBounds.right
        }
      })()
      """,
      &assert(&1 == %{"action" => true, "headers" => true, "wrapper" => true})
    )
  end

  defp assert_minimum_tap_target(session, selector) do
    evaluate(
      session,
      """
      (() => {
        const bounds = document.querySelector(#{Jason.encode!(selector)}).getBoundingClientRect()
        return bounds.width >= 44 && bounds.height >= 44
      })()
      """,
      &assert(&1 == true)
    )
  end

  defp tab_until(session, selector) do
    Enum.reduce_while(1..80, session, fn _, session ->
      session = press(session, "body", "Tab")

      session
      |> evaluate("document.activeElement.matches(#{Jason.encode!(selector)})", fn reached? ->
        send(self(), {:focus_reached, reached?})
      end)

      reached? = receive do: ({:focus_reached, reached?} -> reached?)
      if reached?, do: {:halt, session}, else: {:cont, session}
    end)
  end

  defp select_option(conn, selector, label) do
    unwrap(conn, fn %{frame_id: frame_id} ->
      assert {:ok, _} =
               PlaywrightEx.Frame.select_option(frame_id,
                 selector: selector,
                 options: [%{label: label}],
                 timeout: 2000
               )
    end)
  end

  defp interface_fixture(scope, resource_name, interface_name) do
    {:ok, resource} =
      Inventory.create_resource(scope, %{
        kind: "switch",
        name: resource_name,
        lifecycle_state: "active"
      })

    {:ok, interface} = Inventory.create_interface(scope, resource.id, %{name: interface_name})
    {resource, interface}
  end
end
