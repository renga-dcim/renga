defmodule RengaWeb.Browser.RequestKeyboardTest do
  use PhoenixTest.Playwright.Case, async: true

  import Renga.AccountsFixtures
  import Renga.InventoryFixtures

  alias Renga.Inventory
  alias Renga.Requests

  @moduletag :playwright

  setup %{conn: conn} do
    organization = organization_fixture()
    admin = user_fixture()
    member = user_fixture()
    organization_membership_fixture(admin, organization, %{role: "admin"})
    organization_membership_fixture(member, organization, %{role: "member"})
    admin_scope = Renga.Accounts.scope_for_user(admin, organization.id)
    member_scope = Renga.Accounts.scope_for_user(member, organization.id)

    {:ok, resource} =
      Inventory.create_resource(admin_scope, %{
        kind: "server",
        name: "web-01",
        lifecycle_state: "active"
      })

    {:ok, request} =
      Requests.request_lifecycle(member_scope, resource, %{
        "value" => "retired",
        "reason" => "Refresh"
      })

    conn =
      add_session_cookie(
        conn,
        [
          value: %{
            user_token: Renga.Accounts.generate_user_session_token(admin),
            current_organization_id: organization.id
          }
        ],
        RengaWeb.Endpoint.session_options()
      )

    %{conn: conn, request: request}
  end

  test "Tab and Enter open a request from All and the Requests tab", context do
    for path <- ["/inbox", "/inbox?group=requests"] do
      session = context.conn |> visit(path) |> assert_has("body .phx-connected")

      # Traverse the real tab order, rather than programmatically focusing the link.
      session =
        Enum.reduce_while(1..60, session, fn _, session ->
          session = press(session, "body", "Tab")

          evaluate(
            session,
            "document.activeElement.id === 'request-link-#{context.request.id}'",
            fn reached? -> send(self(), {:request_focused, reached?}) end
          )

          reached? = receive do: ({:request_focused, reached?} -> reached?)

          if reached?, do: {:halt, session}, else: {:cont, session}
        end)

      session
      |> assert_has("#request-link-#{context.request.id}:focus")
      |> press(":focus", "Enter")
      |> assert_has("#request-panel [role=dialog]")
      |> assert_has("#request-approve")
    end
  end
end
