defmodule RengaWeb.Browser.LoginOrganizationTest do
  @moduledoc """
  Signing in again after logging out with a second tab open, in a real
  browser. Logging out disconnects the other tab, which reloads its page,
  finds no session, and leaves that page as the return-to path. The next
  sign-in still opens the user's only organization there instead of
  stopping at the organization picker.
  """
  use PhoenixTest.Playwright.Case, async: true

  import Renga.AccountsFixtures
  import Renga.InventoryFixtures

  alias PhoenixTest.Playwright
  alias PhoenixTest.Playwright.Config
  alias PlaywrightEx.BrowserContext

  @moduletag :playwright

  test "a tab reloaded by logging out reopens in the only organization", %{conn: conn} do
    user = user_fixture()
    organization_membership_fixture(user, organization_fixture(), %{role: "owner"})

    conn
    |> log_in(user)
    |> assert_path("/inbox")

    other_tab =
      conn
      |> new_tab()
      |> visit("/places")
      |> assert_has("body .phx-connected")

    conn
    |> click("a[aria-label='Log out']:visible")
    |> assert_path("/users/log-in")
    |> assert_has("body .phx-connected")

    other_tab
    |> assert_path("/users/log-in")
    |> assert_has("body .phx-connected")

    conn
    |> log_in(user)
    |> assert_path("/places")
    |> assert_has("body .phx-connected")
  end

  # A magic link, so no typed field can be lost to the sign-in page
  # reconnecting while the other tab settles.
  defp log_in(conn, user) do
    {token, _hashed_token} = generate_user_magic_link_token(user)

    conn
    |> visit("/users/log-in/#{token}")
    |> assert_has("body .phx-connected")
    |> click_button("Log me in only this time")
  end

  # A second page in the same browser context, sharing its cookies.
  defp new_tab(%Playwright{} = conn) do
    {:ok, page} = BrowserContext.new_page(conn.context_id, timeout: Config.global(:timeout))

    Playwright.build(%{
      context_id: conn.context_id,
      page_id: page.guid,
      frame_id: page.main_frame.guid,
      tracing_id: conn.tracing_id,
      config: Config.global()
    })
  end
end
