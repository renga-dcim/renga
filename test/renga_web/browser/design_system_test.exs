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

  @brand_render """
  (() => {
    const fill = selector => getComputedStyle(document.querySelector(selector)).fill
    const color = selector => getComputedStyle(document.querySelector(selector)).color
    const size = selector => {
      const box = document.querySelector(selector).getBoundingClientRect()
      return {width: box.width, height: box.height}
    }

    return {
      accent: color("#brand-mark"),
      foreground: color("body"),
      mark: fill("#brand-mark rect"),
      wordmark_r: fill("#brand-wordmark g rect"),
      wordmark_letters: fill("#brand-wordmark > rect"),
      one_tone_r: fill("#brand-wordmark-one-tone g rect"),
      one_tone_letters: fill("#brand-wordmark-one-tone > rect"),
      mark_size: size("#brand-mark"),
      inverted_size: size("#brand-mark-inverted"),
      tile_size: size("#brand-mark-tile"),
      wordmark_size: size("#brand-wordmark"),
      caps_size: size("#brand-wordmark-caps"),
      one_tone_size: size("#brand-wordmark-one-tone")
    }
  })()
  """

  @favicon_render """
  (async () => {
    const image = new Image()
    image.src = "/favicon.svg"
    await image.decode()

    const canvas = document.createElement("canvas")
    canvas.width = 16
    canvas.height = 16
    const context = canvas.getContext("2d")
    context.drawImage(image, 0, 0, 16, 16)
    const pixels = context.getImageData(0, 0, 16, 16).data
    const alpha = (x, y) => pixels[(y * 16 + x) * 4 + 3]
    let painted = 0

    for (let i = 3; i < pixels.length; i += 4) {
      if (pixels[i] > 0) painted++
    }

    return {
      painted,
      corners_transparent: [[0, 0], [15, 0], [0, 15], [15, 15]].every(([x, y]) => alpha(x, y) === 0),
      center_transparent: alpha(8, 8) === 0
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
    # Each switch patches to a URL rendered from the current preview, so wait
    # for one patch to land before the next click or it undoes the last one.
    |> click("#preview-accent-petrol")
    |> assert_has("#preview-accent-petrol[aria-current]")
    |> click("#preview-theme-dark")
    |> assert_has("#preview-theme-dark[aria-current]")
    |> click("#preview-density-compact")
    |> assert_has("#preview-density-compact[aria-current]")
    |> assert_has("#preview-accent-petrol[aria-current]")
    |> assert_has("#preview-theme-dark[aria-current]")
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

  test "brand variants follow the accent and foreground at their intended proportions", %{
    conn: conn
  } do
    for path <- [
          "/dev/design-system?accent=copper&density=comfortable&theme=light",
          "/dev/design-system?accent=petrol&density=comfortable&theme=dark"
        ] do
      conn
      |> visit(path)
      |> assert_has("body .phx-connected")
      |> evaluate(@brand_render, &assert_brand_render/1)
    end
  end

  test "the SVG favicon paints the clipped tile at 16 pixels", %{conn: conn} do
    conn
    |> visit("/dev/design-system")
    |> assert_has("body .phx-connected")
    |> evaluate(@favicon_render, fn rendering ->
      assert rendering["painted"] > 40
      assert rendering["painted"] < 200
      assert rendering["corners_transparent"] == true
      assert rendering["center_transparent"] == true
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

  test "expandable rows expose their state and focus treatments stay visible", %{conn: conn} do
    conn
    |> visit("/dev/design-system")
    |> assert_has("body .phx-connected")
    |> assert_has(
      "#sample-port-1-link[aria-expanded='false'][aria-controls='sample-port-1-details']"
    )
    |> click("#sample-port-1-link")
    |> assert_has("#sample-port-1-link[aria-expanded='true']")
    |> assert_has("#sample-port-1-details", text: "Observed VLAN 30 is not desired")
    |> press("body", "Tab")
    |> evaluate(
      """
      (() => {
        const fallback = document.querySelector('#component-overlays a')
        const owned = document.querySelector('#component-buttons button')
        fallback.focus()
        const fallbackStyle = getComputedStyle(fallback)
        const fallbackOutline = fallbackStyle.outlineStyle
        const fallbackWidth = parseFloat(fallbackStyle.outlineWidth)
        owned.focus()
        const ownedStyle = getComputedStyle(owned)
        return {
          fallback_outline: fallbackOutline,
          fallback_width: fallbackWidth,
          owned_ring: ownedStyle.boxShadow !== 'none'
        }
      })()
      """,
      fn styles ->
        assert styles["fallback_outline"] == "solid"
        assert styles["fallback_width"] == 4
        assert styles["owned_ring"] == true
      end
    )
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
    |> hover(long)
    |> evaluate(
      @tooltip,
      &assert(&1 =~ "Billing analytics warehouse replica (us-east, cold standby)")
    )
    |> evaluate(
      """
      (() => {
        const clip = document.getElementById('sample-clipped-action').closest('[data-clip]')
        return clip.scrollWidth > clip.clientWidth
      })()
      """,
      &assert(&1 == true)
    )
    |> click("#sample-clipped-action")
    |> assert_has("#sample-clipped-action", "Inspected")
    |> assert_has("#sample-clipped-action:focus")
    |> evaluate("window.location.search", &assert(&1 == ""))
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
    # Touch only once the long value has rendered and clips.
    |> assert_has("#sample-standalone-clip[tabindex='0']")
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

  defp assert_brand_render(rendering) do
    assert rendering["mark"] == rendering["accent"]
    assert rendering["wordmark_r"] == rendering["accent"]
    assert rendering["wordmark_letters"] == rendering["foreground"]
    assert rendering["one_tone_r"] == rendering["foreground"]
    assert rendering["one_tone_letters"] == rendering["foreground"]

    for key <- ~w(mark_size inverted_size tile_size) do
      assert_in_delta rendering[key]["width"], 48, 0.1
      assert_in_delta rendering[key]["height"], 48, 0.1
    end

    assert_in_delta rendering["wordmark_size"]["height"], 40, 0.1
    assert_in_delta rendering["wordmark_size"]["width"] / 40, 113 / 33.2, 0.02
    assert_in_delta rendering["caps_size"]["height"], 28, 0.1
    assert_in_delta rendering["caps_size"]["width"] / 28, 113 / 24, 0.02
    assert_in_delta rendering["one_tone_size"]["height"], 24, 0.1
    assert_in_delta rendering["one_tone_size"]["width"] / 24, 113 / 33.2, 0.02
  end
end
