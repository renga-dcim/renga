defmodule RengaWeb.Browser.CommandMenuTest do
  @moduledoc """
  Drives the command menu in a real browser: the keyboard path through page
  actions, unavailable actions that stay readable, and the menu surviving
  server updates now that it is no longer frozen with phx-update="ignore".
  """
  use PhoenixTest.Playwright.Case, async: true

  import Renga.AccountsFixtures
  import Renga.InventoryFixtures

  alias Renga.Inventory

  @moduletag :playwright

  setup %{conn: conn} do
    organization = organization_fixture()
    admin = user_fixture()
    organization_membership_fixture(admin, organization, %{role: "admin"})
    scope = Renga.Accounts.scope_for_user(admin, organization.id)

    {:ok, server} =
      Inventory.create_resource(scope, %{
        kind: "server",
        name: "compute-01",
        lifecycle_state: "active",
        spec: %{}
      })

    %{conn: conn, organization: organization, admin: admin, server: server}
  end

  defp sign_in(conn, user, organization) do
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
  end

  defp open_menu(conn) do
    conn
    |> press("body", "Control+k")
    |> assert_has("#command-palette[open]")
  end

  test "Enter on an unavailable action keeps the menu open with its reason", context do
    member = user_fixture()
    organization_membership_fixture(member, context.organization, %{role: "member"})

    context.conn
    |> sign_in(member, context.organization)
    |> visit("/inventory/#{context.server.id}")
    |> assert_has("body .phx-connected")
    |> open_menu()
    |> press("#command-palette-input", "Enter")
    |> assert_has("#command-palette[open]")
    |> assert_has("#command-change-lifecycle-reason", text: "Requires the owner or admin role")
  end

  test "running an action closes the menu and does it", context do
    context.conn
    |> sign_in(context.admin, context.organization)
    |> visit("/inventory/#{context.server.id}")
    |> assert_has("body .phx-connected")
    |> open_menu()
    |> press("#command-palette-input", "Enter")
    |> refute_has("#command-palette[open]")
    |> assert_has("#resource-lifecycle-form select:focus")
  end

  test "Tab and Enter activate the focused action rather than the first result", context do
    context.conn
    |> sign_in(context.admin, context.organization)
    |> visit("/inventory/#{context.server.id}")
    |> assert_has("body .phx-connected")
    |> open_menu()
    |> press("#command-palette-input", "Tab")
    |> assert_has("#command-change-lifecycle:focus")
    |> press("#command-change-lifecycle", "Tab")
    |> assert_has("#command-open-hardware:focus")
    |> press("#command-open-hardware", "Enter")
    |> assert_has("#resource-hardware")
    |> refute_has("#command-palette[open]")
    |> assert_has("body .phx-connected")
  end

  test "arrow navigation exposes unavailable actions and Escape restores the opener", context do
    member = user_fixture()
    organization_membership_fixture(member, context.organization, %{role: "member"})

    context.conn
    |> sign_in(member, context.organization)
    |> visit("/inventory/#{context.server.id}")
    |> assert_has("body .phx-connected")
    |> evaluate("document.querySelector('#command-palette-trigger').focus()")
    |> open_menu()
    |> press("#command-palette-input", "ArrowUp")
    |> press("#command-palette [data-command-action='toggle-theme']", "ArrowDown")
    |> assert_has(
      "#command-change-lifecycle:focus[aria-disabled='true'][aria-describedby='command-change-lifecycle-reason']",
      text: "Change lifecycle"
    )
    |> press("#command-change-lifecycle", "Enter")
    |> assert_has("#command-palette[open]")
    |> assert_has("#command-change-lifecycle-reason", text: "Requires the owner or admin role")
    |> press("#command-change-lifecycle", "Escape")
    |> refute_has("#command-palette[open]")
    |> assert_has("#command-palette-trigger:focus")
  end

  test "the open menu keeps its query, filter and selected action through a server update",
       context do
    context.conn
    |> sign_in(context.admin, context.organization)
    |> visit("/inventory/#{context.server.id}")
    |> assert_has("body .phx-connected")
    |> open_menu()
    |> type("#command-palette-input", "hardware")
    |> assert_has("#command-open-hardware")
    |> refute_has("#command-change-lifecycle:not([hidden])")
    |> press("#command-palette-input", "ArrowDown")
    |> assert_has("#command-open-hardware:focus")
    # Change the resource from the server while the menu is open.
    |> evaluate("""
    liveSocket.execJS(document.querySelector("[data-phx-main]"), JSON.stringify([
      ["push", {event: "update_lifecycle", value: {lifecycle: {lifecycle_state: "inactive"}}}]
    ]))
    """)
    |> assert_has("#flash-info", text: "Resource lifecycle updated")
    |> assert_has("#command-palette[open]")
    |> evaluate(
      "document.querySelector('#command-palette-input').value",
      &assert(&1 == "hardware")
    )
    |> refute_has("#command-change-lifecycle:not([hidden])")
    |> assert_has("#command-open-hardware:focus[class~='bg-base-content/[0.06]']")
    |> press("#command-open-hardware", "Enter")
    |> assert_has("#resource-hardware")
    |> assert_has("body .phx-connected")
  end

  test "selection follows command identity when a preceding command disappears", context do
    context.conn
    |> sign_in(context.admin, context.organization)
    |> visit("/inventory/#{context.server.id}")
    |> assert_has("body .phx-connected")
    |> open_menu()
    |> press("#command-palette-input", "ArrowDown")
    |> assert_has("#command-open-hardware:focus")
    |> evaluate("""
    document.querySelector('#command-change-lifecycle').remove();
    liveSocket.execJS(document.querySelector("[data-phx-main]"), JSON.stringify([
      ["push", {event: "update_lifecycle", value: {lifecycle: {lifecycle_state: "inactive"}}}]
    ]))
    """)
    |> assert_has("#flash-info", text: "Resource lifecycle updated")
    |> assert_has("#command-open-hardware:focus[class~='bg-base-content/[0.06]']")
    |> press("#command-open-hardware", "Enter")
    |> assert_has("#resource-hardware")
    |> assert_has("body .phx-connected")
  end

  test "a removed selection falls back to the first remaining result after a patch", context do
    context.conn
    |> sign_in(context.admin, context.organization)
    |> visit("/inventory/#{context.server.id}")
    |> assert_has("body .phx-connected")
    |> open_menu()
    |> type("#command-palette-input", "hardware")
    |> press("#command-palette-input", "ArrowDown")
    |> assert_has("#command-open-hardware:focus")
    # Simulate a command being removed; the real server patch refreshes the hook.
    |> evaluate("""
    document.querySelector('#command-open-hardware').remove();
    liveSocket.execJS(document.querySelector("[data-phx-main]"), JSON.stringify([
      ["push", {event: "update_lifecycle", value: {lifecycle: {lifecycle_state: "inactive"}}}]
    ]))
    """)
    |> assert_has("#flash-info", text: "Resource lifecycle updated")
    |> assert_has("#command-resource-search a:focus")
    |> press("#command-resource-search a", "Enter")
    |> assert_has("#filters_search[value='hardware']")
    |> assert_has("body .phx-connected")
  end
end
