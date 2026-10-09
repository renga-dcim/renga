defmodule RengaWeb.Browser.AppearanceTest do
  @moduledoc """
  Appearance in a real browser, where the CSS tokens resolve: choosing an
  accent, theme, or density applies at once, survives a reload because it
  is saved to the account, and the settings page fits a phone.
  """
  use PhoenixTest.Playwright.Case, async: true

  import Renga.AccountsFixtures
  import Renga.InventoryFixtures

  @moduletag :playwright

  setup %{conn: conn} do
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

    %{conn: conn, user: user}
  end

  @accent "getComputedStyle(document.documentElement).getPropertyValue('--rg-accent').trim()"
  @root "(() => { const d = document.documentElement.dataset; return [d.theme || null, d.accent, d.density] })()"

  test "choices apply at once and follow the account across reloads", %{conn: conn, user: user} do
    conn
    |> visit("/settings/appearance")
    |> assert_has("body .phx-connected")
    |> evaluate(@accent, &assert(&1 == "#b4531c"))
    |> click("label:has(#accent-petrol)")
    |> assert_has("#accent-petrol[checked]")
    |> evaluate(@accent, &assert(&1 == "#0b6e7f"))
    |> click("label:has(#theme-dark)")
    |> click("label:has(#density-compact)")
    |> assert_has("#density-compact[checked]")
    |> evaluate(@root, &assert(&1 == ["dark", "petrol", "compact"]))
    |> visit("/inbox")
    |> assert_has("body .phx-connected")
    |> evaluate(@root, &assert(&1 == ["dark", "petrol", "compact"]))
    |> evaluate(@accent, &assert(&1 == "#3ba7b8"))

    assert %{theme: "dark", accent: "petrol", density: "compact"} =
             Renga.Accounts.get_user!(user.id)
  end

  test "the theme button cycles through system, light, and dark", %{conn: conn} do
    conn
    |> visit("/inbox")
    |> assert_has("body .phx-connected")
    |> evaluate(@root, &assert(hd(&1) == nil))
    |> click("#theme-toggle")
    |> evaluate(
      "new Promise(r => setTimeout(() => r(document.documentElement.dataset.theme), 300))",
      &assert(&1 == "light")
    )
    |> click("#theme-toggle")
    |> evaluate(
      "new Promise(r => setTimeout(() => r(document.documentElement.dataset.theme), 300))",
      &assert(&1 == "dark")
    )
  end

  test "the command menu's Switch theme saves the choice too", %{conn: conn, user: user} do
    conn
    |> visit("/inbox")
    |> assert_has("body .phx-connected")
    |> evaluate("window.dispatchEvent(new Event('renga:open-command-palette'))")
    |> assert_has("#command-palette[open]")
    |> click("#command-palette [data-command-action='toggle-theme']")
    |> evaluate(
      "new Promise(r => setTimeout(() => r(document.documentElement.dataset.theme), 300))",
      &assert(&1 == "light")
    )

    assert Renga.Accounts.get_user!(user.id).theme == "light"
  end

  test "live navigation applies freshly stored preferences without replacing the document", %{
    conn: conn,
    user: user
  } do
    session = conn |> visit("/settings/collectors") |> assert_has("body .phx-connected")
    session |> evaluate("window.appearanceNavigationMarker = true")

    {:ok, _} =
      Renga.Accounts.update_user_appearance(user, %{
        theme: "dark",
        accent: "iris",
        density: "compact"
      })

    session
    |> click_link("a[href='/settings/appearance']:visible", "Appearance")
    |> assert_has("#theme-dark[checked]")
    |> evaluate(@root, &assert(&1 == ["dark", "iris", "compact"]))
    |> evaluate("window.appearanceNavigationMarker", &assert(&1 == true))
    |> evaluate(
      "window.dispatchEvent(new StorageEvent('storage', {key: 'phx:theme', newValue: 'light'}))"
    )
    |> evaluate(@root, &assert(&1 == ["dark", "iris", "compact"]))
  end

  @tag browser_context_opts: [
         has_touch: true,
         is_mobile: true,
         viewport: %{width: 390, height: 844}
       ]
  test "fits a phone with tappable choices", %{conn: conn} do
    conn
    |> visit("/settings/appearance")
    |> assert_has("body .phx-connected")
    |> evaluate(
      "document.documentElement.scrollWidth <= document.documentElement.clientWidth",
      &assert(&1 == true)
    )
    |> evaluate(
      "[...document.querySelectorAll('#appearance label')].map(l => l.getBoundingClientRect().height)",
      fn heights ->
        assert heights != []
        assert Enum.all?(heights, &(round(&1) >= 44))
      end
    )
  end
end
