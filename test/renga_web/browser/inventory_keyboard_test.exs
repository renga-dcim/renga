defmodule RengaWeb.Browser.InventoryKeyboardTest do
  @moduledoc """
  The list's keyboard grammar (RFD 8) in a real browser: J/K move between
  rows, X selects the focused row and keeps focus on it after the server
  re-renders, F jumps to search without typing an "f", and Enter opens the
  focused row.
  """
  use PhoenixTest.Playwright.Case, async: true

  import Renga.AccountsFixtures
  import Renga.InventoryFixtures

  alias Renga.Inventory

  @moduletag :playwright

  setup %{conn: conn} do
    organization = organization_fixture()
    user = user_fixture()
    organization_membership_fixture(user, organization, %{role: "admin"})
    scope = Renga.Accounts.scope_for_user(user, organization.id)

    [alpha, bravo] =
      for name <- ["alpha-01", "bravo-01"] do
        {:ok, resource} = Inventory.create_resource(scope, %{kind: "server", name: name})
        resource
      end

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

    %{conn: conn, alpha: alpha, bravo: bravo}
  end

  test "J/K move, X selects without losing the row, F searches, Enter opens", context do
    %{alpha: alpha, bravo: bravo} = context

    context.conn
    |> visit("/inventory")
    |> assert_has("body .phx-connected")
    |> press("body", "j")
    |> assert_has("#resources-#{alpha.id} a:focus")
    |> press(":focus", "j")
    |> assert_has("#resources-#{bravo.id} a:focus")
    |> press(":focus", "x")
    |> assert_has("#bulk-count", text: "1 resource selected")
    |> assert_has("#resources-#{bravo.id} [data-list-check]:checked")
    |> assert_has("#resources-#{bravo.id} a:focus")
    |> press(":focus", "k")
    |> assert_has("#resources-#{alpha.id} a:focus")
    |> press(":focus", "f")
    |> assert_has("#resource-search-input:focus")
    |> evaluate("document.querySelector('#resource-search-input').value", &assert(&1 == ""))
    |> press("#resources-#{alpha.id} a", "Enter")
    |> assert_has("#resource-detail")
  end

  test "keys do nothing while typing in search", context do
    context.conn
    |> visit("/inventory")
    |> assert_has("body .phx-connected")
    |> type("#resource-search-input", "jx")
    |> refute_has("#bulk-bar")
    |> refute_has("#resources a:focus")
  end
end
