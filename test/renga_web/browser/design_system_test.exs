defmodule RengaWeb.Browser.DesignSystemTest do
  @moduledoc """
  Verifies the living design system in a real browser, where CSS variables,
  media queries, density, touch targets, and overlay focus behavior resolve.
  """
  use PhoenixTest.Playwright.Case, async: true

  @moduletag :playwright

  @appearance """
  (() => {
    const root = document.documentElement
    const style = getComputedStyle(root)

    return {
      theme: root.dataset.theme || null,
      theme_pref: root.dataset.themePref,
      accent: root.dataset.accent,
      density: root.dataset.density,
      accent_color: style.getPropertyValue("--rg-accent").trim()
    }
  })()
  """

  @sizes """
  (() => {
    const row = document.querySelector("#sample-nodes tr:not([data-list-group]):not(#sample-nodes-empty)")
    const cell = row.querySelector("td")

    return {
      row: row.getBoundingClientRect().height,
      button: document.querySelector("#component-buttons button").getBoundingClientRect().height,
      table_text: parseFloat(getComputedStyle(cell).fontSize)
    }
  })()
  """

  test "theme, accent, and density controls change the rendered tokens and survive reload", %{
    conn: conn
  } do
    session =
      conn
      |> visit("/")
      |> evaluate("localStorage.setItem('phx:theme', 'light')")
      |> visit("/dev/design-system")
      |> assert_has("body .phx-connected")
      |> refute_has("#theme-toggle-header")

    session
    |> evaluate(@appearance, fn appearance ->
      assert appearance == %{
               "accent" => "copper",
               "accent_color" => "#b4531c",
               "density" => "comfortable",
               "theme" => nil,
               "theme_pref" => "system"
             }
    end)
    |> evaluate(@sizes, &assert(&1 == %{"row" => 36, "button" => 32, "table_text" => 13}))
    |> click("#preview-accent-petrol")
    |> click("#preview-theme-dark")
    |> click("#preview-density-compact")
    |> assert_has("#preview-accent-petrol[aria-current]")
    |> assert_has("#preview-theme-dark[aria-current]")
    |> assert_has("#preview-density-compact[aria-current]")
    |> evaluate(@appearance, fn appearance ->
      assert appearance == %{
               "accent" => "petrol",
               "accent_color" => "#3ba7b8",
               "density" => "compact",
               "theme" => "dark",
               "theme_pref" => "dark"
             }
    end)
    |> evaluate(@sizes, &assert(&1 == %{"row" => 28, "button" => 28, "table_text" => 12}))
    |> evaluate("localStorage.getItem('phx:theme')", &assert(&1 == "light"))

    session
    |> visit("/dev/design-system?accent=petrol&density=compact&theme=dark")
    |> assert_has("#preview-accent-petrol[aria-current]")
    |> assert_has("#preview-theme-dark[aria-current]")
    |> assert_has("#preview-density-compact[aria-current]")
    |> evaluate("localStorage.getItem('phx:theme')", &assert(&1 == "light"))
  end

  @tag browser_context_opts: [color_scheme: :dark]
  test "system theme follows a dark browser without forcing data-theme", %{conn: conn} do
    conn
    |> visit("/dev/design-system?accent=copper&density=comfortable&theme=system")
    |> assert_has("body .phx-connected")
    |> evaluate(@appearance, fn appearance ->
      assert appearance["theme"] == nil
      assert appearance["theme_pref"] == "system"
      assert appearance["accent_color"] == "#e07a3f"
    end)
  end

  test "sample overlays trap focus and Escape restores the opener", %{conn: conn} do
    conn
    |> visit("/dev/design-system")
    |> assert_has("body .phx-connected")
    |> click("#open-sample-panel")
    |> assert_has("#sample-panel [role=dialog]")
    |> evaluate(
      "document.querySelector('#sample-panel [role=dialog]').contains(document.activeElement)",
      &assert(&1 == true)
    )
    |> press("#sample-panel [role=dialog]", "Escape")
    |> refute_has("#sample-panel [role=dialog]")
    |> assert_has("#open-sample-panel:focus")
    |> click("#open-sample-dialog")
    |> assert_has("#sample-dialog [role=alertdialog]")
    |> press("#sample-dialog [role=alertdialog]", "Escape")
    |> refute_has("#sample-dialog [role=alertdialog]")
    |> assert_has("#open-sample-dialog:focus")
  end

  @tag browser_context_opts: [
         has_touch: true,
         is_mobile: true,
         viewport: %{width: 390, height: 844}
       ]
  test "mobile controls fit the page and keep touch targets at both densities", %{conn: conn} do
    session =
      conn
      |> visit("/dev/design-system")
      |> assert_has("body .phx-connected")

    for density <- ~w(comfortable compact) do
      session
      |> click("#preview-density-#{density}")
      |> assert_has("#preview-density-#{density}[aria-current]")
      |> click("#preview-accent-mono")
      |> assert_has("#preview-accent-mono[aria-current]")
      |> evaluate(
        "document.documentElement.scrollWidth <= document.documentElement.clientWidth",
        &assert(&1 == true)
      )
      |> evaluate(
        "[...document.querySelectorAll('#preview-controls a')].map(el => el.getBoundingClientRect().height)",
        fn heights ->
          assert heights != []
          assert Enum.all?(heights, &(round(&1) >= 44))
        end
      )
    end
  end
end
