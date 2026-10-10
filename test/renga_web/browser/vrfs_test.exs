defmodule RengaWeb.Browser.VrfsTest do
  @moduledoc """
  The VRF list in a real browser: an admin creates, renames, and deletes a
  VRF through the side panel and confirmation dialog, and at phone width the
  list and the routing domains collectors report stay readable without
  horizontal scrolling and without controls, because VRFs are not edited on
  a phone.
  """
  use PhoenixTest.Playwright.Case, async: true

  import Renga.AccountsFixtures
  import Renga.InventoryFixtures
  import Renga.TopologyFixtures

  @moduletag :playwright

  setup %{conn: conn} do
    organization = organization_fixture()
    user = user_fixture()
    organization_membership_fixture(user, organization, %{role: "admin"})
    scope = Renga.Accounts.scope_for_user(user, organization.id)

    blue =
      vrf_fixture(scope, "blue", %{
        route_distinguisher: "65000:4294967295",
        description: "Tenant network for the blue customer"
      })

    prefix_fixture(scope, "10.0.0.0/24", %{vrf: "blue"})
    vrf_fixture(scope, "tenant-" <> String.duplicate("blue", 20))

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

    %{conn: conn, scope: scope, blue: blue}
  end

  test "an admin creates, renames, and deletes a VRF", context do
    session =
      context.conn
      |> visit("/network/vrfs")
      |> assert_has("body .phx-connected")
      |> PhoenixTest.Playwright.click("#new-vrf")
      |> assert_has("#vrf-panel [role=dialog]", text: "New VRF")
      |> fill_in("#vrf-form input[name='vrf[name]']", "Name", with: "BLUE")
      |> PhoenixTest.Playwright.click("#save-vrf")
      |> assert_has("#vrf-panel [role=dialog]", text: "is already a VRF in this organization")
      |> fill_in("#vrf-form input[name='vrf[name]']", "Name", with: "red")
      |> PhoenixTest.Playwright.click("#save-vrf")
      |> assert_has("#flash-info", text: "VRF red created")
      |> refute_has("#vrf-panel [role=dialog]")

    red = Renga.IPAM.get_vrf_by_name(context.scope, "red")

    session
    |> PhoenixTest.Playwright.click("#vrf-#{red.id}-edit")
    |> assert_has("#vrf-panel [role=dialog]", text: "Edit red")
    |> fill_in("#vrf-form input[name='vrf[name]']", "Name", with: "green")
    |> PhoenixTest.Playwright.click("#save-vrf")
    |> assert_has("#vrf-#{red.id}", text: "green")
    |> PhoenixTest.Playwright.click("#vrf-#{red.id}-delete")
    |> assert_has("#delete-vrf-#{red.id} [role=alertdialog]", text: "Delete green?")
    |> PhoenixTest.Playwright.click("#delete-vrf-#{red.id}-confirm")
    |> assert_has("#flash-info", text: "VRF green deleted")
    |> refute_has("#vrf-#{red.id}")
    |> evaluate(
      "document.getElementById('vrf-#{context.blue.id}-delete').disabled",
      &assert(&1 == true)
    )
  end

  test "cancelled drafts cannot leak into another edit or a fresh create", context do
    other = vrf_fixture(context.scope, "red", %{description: "Red original"})

    session =
      context.conn
      |> visit("/network/vrfs")
      |> assert_has("body .phx-connected")
      |> PhoenixTest.Playwright.click("#vrf-#{context.blue.id}-edit")
      |> assert_has("#vrf-panel", text: "Edit blue")
      |> fill_in("#vrf-form input[name='vrf[description]']", "Description (optional)",
        with: "Cancelled draft"
      )
      |> PhoenixTest.Playwright.click("#vrf-panel button[aria-label=Close]")
      |> refute_has("#vrf-form")
      |> evaluate("window.liveSocket.enableLatencySim(400)")
      |> PhoenixTest.Playwright.click("#vrf-#{other.id}-edit")
      |> evaluate(
        "document.querySelector('#vrf-form input')?.focus(); document.querySelector('#vrf-form') === null",
        &assert(&1 == true)
      )
      |> assert_has("#vrf-panel", text: "Edit red")
      |> evaluate(
        "document.querySelector('#vrf-form input[name=\"vrf[description]\"]').value",
        &assert(&1 == "Red original")
      )
      |> evaluate("window.liveSocket.disableLatencySim()")
      |> PhoenixTest.Playwright.click("#vrf-panel button[aria-label=Close]")
      |> refute_has("#vrf-form")
      |> PhoenixTest.Playwright.click("#new-vrf")
      |> assert_has("#vrf-panel", text: "New VRF")
      |> evaluate(
        "document.querySelector('#vrf-form input[name=\"vrf[name]\"]').value",
        &assert(&1 == "")
      )
      |> fill_in("#vrf-form input[name='vrf[name]']", "Name", with: "default")
      |> PhoenixTest.Playwright.click("#save-vrf")
      |> assert_has("#vrf-form", text: "is reserved")
      |> PhoenixTest.Playwright.click("#vrf-panel button[aria-label=Close]")
      |> refute_has("#vrf-form")

    session
    |> PhoenixTest.Playwright.click("#new-vrf")
    |> assert_has("#vrf-panel", text: "New VRF")
    |> refute_has("#vrf-form", text: "is reserved")
    |> evaluate(
      "document.querySelector('#vrf-form input[name=\"vrf[name]\"]').value",
      &assert(&1 == "")
    )
  end

  test "stale focused edits preserve drafts and reopen with current values", context do
    session =
      context.conn
      |> visit("/network/vrfs")
      |> assert_has("body .phx-connected")
      |> PhoenixTest.Playwright.click("#vrf-#{context.blue.id}-edit")
      |> assert_has("#vrf-panel", text: "Edit blue")
      |> fill_in("#vrf-form input[name='vrf[description]']", "Description (optional)",
        with: "My draft"
      )

    {:ok, _} = Renga.IPAM.update_vrf(context.scope, context.blue, %{description: "External"})

    session =
      session
      |> assert_has("#vrf-#{context.blue.id}", text: "External")
      |> evaluate(
        "document.querySelector('#vrf-form input[name=\"vrf[description]\"]').value",
        &assert(&1 == "My draft")
      )
      |> PhoenixTest.Playwright.click("#save-vrf")
      |> assert_has("#vrf-edit-conflict", text: "This VRF changed elsewhere")
      |> PhoenixTest.Playwright.click("#vrf-panel button[aria-label=Close]")
      |> refute_has("#vrf-form")
      |> PhoenixTest.Playwright.click("#vrf-#{context.blue.id}-edit")
      |> assert_has("#vrf-panel", text: "Edit blue")
      |> evaluate(
        "document.querySelector('#vrf-form input[name=\"vrf[description]\"]').value",
        &assert(&1 == "External")
      )

    session
    |> fill_in("#vrf-form input[name='vrf[description]']", "Description (optional)",
      with: "Retry"
    )
    |> PhoenixTest.Playwright.click("#save-vrf")
    |> refute_has("#vrf-form")

    assert Renga.IPAM.get_vrf!(context.scope, context.blue.id).description == "Retry"
  end

  test "a delete dialog removed by a live update releases its scroll lock", context do
    empty = vrf_fixture(context.scope, "empty")

    session =
      context.conn
      |> visit("/network/vrfs")
      |> assert_has("body .phx-connected")
      |> PhoenixTest.Playwright.click("#vrf-#{empty.id}-delete")
      |> assert_has("#delete-vrf-#{empty.id} [role=alertdialog]")

    prefix_fixture(context.scope, "192.0.2.0/24", %{vrf: "empty"})

    session
    |> refute_has("#delete-vrf-#{empty.id}")
    |> evaluate(
      """
      new Promise(resolve => {
        const timer = setInterval(() => {
          if (!document.getElementById('delete-vrf-#{empty.id}')) {
            clearInterval(timer)
            resolve(document.body.classList.contains('overflow-hidden'))
          }
        }, 20)
      })
      """,
      &assert(&1 == false)
    )
    |> PhoenixTest.Playwright.click("#new-vrf")
    |> assert_has("#vrf-panel [role=dialog]")
    |> evaluate(
      "document.querySelector('#vrf-panel').contains(document.activeElement)",
      &assert(&1 == true)
    )
  end

  @tag browser_context_opts: [
         has_touch: true,
         is_mobile: true,
         viewport: %{width: 390, height: 844}
       ]
  test "VRFs are readable but not editable on a phone", context do
    context.conn
    |> visit("/network/vrfs")
    |> assert_has("body .phx-connected")
    |> assert_has("#vrf-#{context.blue.id}", text: "blue")
    |> evaluate(visible_js("new-vrf"), &assert(&1 == false))
    |> evaluate(visible_js("vrf-#{context.blue.id}-edit"), &assert(&1 == false))
    |> evaluate(visible_js("vrf-#{context.blue.id}-prefixes"), &assert(&1 == true))
    |> evaluate(
      "(el => {const r = el.getBoundingClientRect(); return [r.width, r.height]})(document.getElementById('vrf-#{context.blue.id}-prefixes'))",
      fn [width, height] -> assert width >= 44 and height >= 44 end
    )
    |> evaluate(
      "document.documentElement.scrollWidth <= document.documentElement.clientWidth",
      &assert(&1 == true)
    )
    # The list itself fits too, so each table's prefix count is never
    # scrolled out of view.
    |> evaluate(
      "(el => el.scrollWidth <= el.clientWidth)(document.getElementById('vrf-list').closest('div'))",
      &assert(&1 == true)
    )
  end

  @tag browser_context_opts: [
         has_touch: true,
         is_mobile: true,
         viewport: %{width: 390, height: 844}
       ]
  test "routing domains are readable but not mapped on a phone", context do
    {:ok, agent} =
      Renga.Inventory.create_source(context.scope, %{kind: "host_agent", name: "agent"})

    long_key = "tenant-" <> String.duplicate("lab", 30)

    {:ok, observation} =
      Renga.Inventory.create_observation(context.scope, agent.id, %{
        idempotency_key: "phone-domains",
        observed_at: ~U[2026-08-01 12:00:00Z],
        payload: %{
          "resources" => [
            %{
              "kind" => "server",
              "identifiers" => %{"machine_id" => "router-1"},
              "interfaces" => [%{"name" => "eth0", "routing_domain" => %{"key" => long_key}}]
            }
          ]
        }
      })

    {:ok, _, _} = Renga.Inventory.reconcile_observation(context.scope, observation.id)
    row = "routing-domain-#{RengaWeb.VrfLive.domain_id(agent.id, long_key)}"

    context.conn
    |> visit("/network/vrfs")
    |> assert_has("body .phx-connected")
    |> assert_has("##{row}", text: "Unmapped")
    |> evaluate(visible_js("#{row}-form"), &assert(&1 == false))
    |> evaluate(visible_js("source-#{agent.id}-authority-form"), &assert(&1 == false))
    |> assert_has("#source-#{agent.id}-authority", text: "Authoritative")
    |> evaluate(
      "document.documentElement.scrollWidth <= document.documentElement.clientWidth",
      &assert(&1 == true)
    )
    |> evaluate(
      "(el => el.scrollWidth <= el.clientWidth)(document.getElementById('routing-domain-list').closest('div'))",
      &assert(&1 == true)
    )
  end

  defp visible_js(id), do: "document.getElementById('#{id}').checkVisibility()"
end
