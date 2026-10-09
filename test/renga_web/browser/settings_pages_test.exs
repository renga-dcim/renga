defmodule RengaWeb.Browser.SettingsPagesTest do
  @moduledoc """
  The sign-in and settings pages at phone width, in a real browser: each
  stays within the screen and its buttons keep 44px touch targets.
  """
  use PhoenixTest.Playwright.Case, async: true

  import Renga.AccountsFixtures
  import Renga.InventoryFixtures

  @moduletag :playwright
  @moduletag browser_context_opts: [
               has_touch: true,
               is_mobile: true,
               viewport: %{width: 390, height: 844}
             ]

  @fits "document.documentElement.scrollWidth <= window.innerWidth"
  @buttons "[...document.querySelectorAll('main button, main input[type=submit]')].filter(b => b.offsetParent !== null).map(b => b.getBoundingClientRect().height)"

  defp tappable(heights), do: Enum.all?(heights, &(round(&1) >= 44))

  test "sign-in and registration fit a phone", %{conn: conn} do
    for path <- ~w(/users/log-in /users/register) do
      conn
      |> visit(path)
      |> assert_has("body .phx-connected")
      |> evaluate(@fits, &assert(&1 == true))
      |> evaluate(@buttons, &assert(tappable(&1), "#{path}: #{inspect(&1)}"))
    end
  end

  test "settings pages fit a phone", %{conn: conn} do
    organization = organization_fixture()
    user = user_fixture()
    organization_membership_fixture(user, organization, %{role: "owner"})

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

    for path <-
          ~w(/users/settings /organizations /settings/collectors /settings/teams /settings/triage-rules /settings/appearance) do
      conn
      |> visit(path)
      |> assert_has("body .phx-connected")
      |> evaluate(@fits, &assert(&1 == true, "#{path} scrolls sideways"))
    end
  end
end
