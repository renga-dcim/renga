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

  @tooltip """
  new Promise(resolve => setTimeout(() => {
    const tooltip = document.getElementById("clip-tooltip")
    resolve(tooltip?.matches(":popover-open") ? tooltip.textContent : null)
  }, 600))
  """

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

  test "only cut-off values show their full text, and +N opens the whole list", %{conn: conn} do
    long = "#sample-overflow tr:nth-child(2) td:first-child [data-clip]"
    short = "#sample-overflow tr:nth-child(1) td:nth-child(2) [data-clip]"

    conn
    |> visit("/dev/design-system")
    |> assert_has("body .phx-connected")
    |> evaluate(
      "[...document.querySelectorAll('#sample-overflow tr')].map(row => row.getBoundingClientRect().height)",
      &assert(&1 == [36, 36])
    )
    |> hover(long)
    |> evaluate(
      @tooltip,
      &assert(&1 =~ "Billing analytics warehouse replica (us-east, cold standby)")
    )
    |> hover(short)
    |> evaluate(@tooltip, &assert(&1 == nil))
    |> click("#sample-overflow tr:nth-child(1) td:nth-child(2)")
    |> assert_path("/dev/design-system", query_params: %{"overflow" => "1"})
    |> visit("/dev/design-system")
    |> click("#sample-overflow tr:nth-child(2) td:nth-child(3) [data-clip]")
    |> evaluate("window.location.search", &assert(&1 == ""))
    |> evaluate(@tooltip, &assert(&1 =~ "Refused: inventory.collect is disabled"))
    |> press(":focus", "Escape")
    |> click("#sample-chips-2-more")
    |> evaluate("window.location.search", &assert(&1 == ""))
    |> evaluate(
      "document.getElementById('sample-chips-2-list').matches(':popover-open')",
      &assert(&1 == true)
    )
    |> evaluate(
      """
      new Promise(resolve => requestAnimationFrame(() => requestAnimationFrame(() => {
        const anchor = document.getElementById('sample-chips-2-more').getBoundingClientRect()
        const popover = document.getElementById('sample-chips-2-list').getBoundingClientRect()
        resolve({below: popover.top >= anchor.bottom, inside: popover.right <= innerWidth})
      })))
      """,
      &assert(&1 == %{"below" => true, "inside" => true})
    )
    |> click("#sample-chips-2-list li:nth-child(2)")
    |> evaluate("window.location.search", &assert(&1 == ""))
    |> press("#sample-chips-2-more", "Escape")
    |> evaluate(
      "document.getElementById('sample-chips-2-list').matches(':popover-open')",
      &assert(&1 == false)
    )
  end

  test "plain clipped values are reachable in the real tab order", %{conn: conn} do
    detail = "#sample-overflow tr:nth-child(2) td:nth-child(3) [data-clip]"

    session =
      conn
      |> visit("/dev/design-system")
      |> assert_has("body .phx-connected")
      |> assert_has("#sample-standalone-clip[tabindex='-1']", "Short value")
      |> click("#toggle-overflow-sample")
      |> assert_has("#sample-standalone-clip[tabindex='0']")
      |> tab_until("#sample-standalone-clip")

    session
    |> assert_has("#sample-standalone-clip:focus")
    |> evaluate(@tooltip, &assert(&1 =~ "Standalone values reveal their full text"))
    |> press(":focus", "Escape")
    |> tab_until(detail)
    |> assert_has("#{detail}:focus")
    |> evaluate(@tooltip, &assert(&1 =~ "Refused: inventory.collect is disabled"))

    session
    |> press(":focus", "Escape")
    |> click("#toggle-overflow-sample")
    |> assert_has("#sample-standalone-clip[tabindex='-1']", "Short value")
    |> press("#toggle-overflow-sample", "Shift+Tab")
    |> evaluate(
      "document.activeElement.id",
      &refute(&1 == "sample-standalone-clip")
    )
  end

  @tag browser_context_opts: [viewport: %{width: 390, height: 844}]
  test "narrow tables drop low-priority columns instead of scrolling", %{conn: conn} do
    conn
    |> visit("/dev/design-system")
    |> assert_has("body .phx-connected")
    |> click("#toggle-overflow-sample")
    |> touch("#sample-standalone-clip")
    |> evaluate(@tooltip, &assert(&1 =~ "Standalone values reveal their full text"))
    |> evaluate(
      """
      (() => {
        const scroller = document.getElementById("sample-overflow").closest("div")
        const shown = [...scroller.querySelectorAll("thead th")]
          .filter(th => getComputedStyle(th).display !== "none")
          .map(th => th.textContent.trim())
        return {shown, scrolls: scroller.scrollWidth > scroller.clientWidth}
      })()
      """,
      &assert(&1 == %{"shown" => ["Target", "State"], "scrolls" => false})
    )
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
