defmodule RengaWeb.DesignSystemLiveTest do
  use RengaWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  test "renders every section of the design system without signing in", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/dev/design-system")

    for section <- ~w(colors typography density shape status components icons) do
      assert has_element?(view, "##{section}")
    end

    assert has_element?(view, "#swatch-accent")
    assert has_element?(view, "#status-attention [data-signal='drift']")
    assert has_element?(view, "#sample-nodes [data-list-group]")
    assert has_element?(view, "#sample-object")
    refute has_element?(view, "#theme-toggle-header")
  end

  test "previews accent, theme, and density from the URL", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/dev/design-system")

    assert has_element?(view, "#preview-accent-copper[aria-current]")
    assert_push_event(view, "appearance", %{accent: "copper", density: "comfortable"})

    view |> element("#preview-accent-petrol") |> render_click()

    assert_patch(view, "/dev/design-system?accent=petrol&density=comfortable&theme=system")
    assert_push_event(view, "appearance", %{accent: "petrol"})
    assert has_element?(view, "#preview-accent-petrol[aria-current]")
    refute has_element?(view, "#preview-accent-copper[aria-current]")
  end

  test "ignores preview values that are not real choices", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/dev/design-system?accent=neon&theme=dark")

    assert_push_event(view, "appearance", %{accent: "copper", theme: "dark"})
    assert has_element?(view, "#preview-theme-dark[aria-current]")
  end

  test "shows flashes on demand", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/dev/design-system")

    view |> element("#show-error-flash") |> render_click()

    assert has_element?(view, "#flash-error")
  end
end
