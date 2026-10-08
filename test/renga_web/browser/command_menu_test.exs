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

  test "the open menu keeps its query and filter through a server update", context do
    context.conn
    |> sign_in(context.admin, context.organization)
    |> visit("/inventory/#{context.server.id}")
    |> assert_has("body .phx-connected")
    |> open_menu()
    |> type("#command-palette-input", "hardware")
    |> assert_has("#command-open-hardware")
    |> refute_has("#command-change-lifecycle:not([hidden])")
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
  end
end
