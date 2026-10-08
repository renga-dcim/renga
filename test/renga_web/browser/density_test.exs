defmodule RengaWeb.Browser.DensityTest do
  @moduledoc """
  Checks the RFD 8 density tokens in a real browser, where CSS custom
  properties and media queries actually resolve. LiveViewTest only sees
  markup, so it cannot tell whether a control is 32px or 28px tall.
  """
  use PhoenixTest.Playwright.Case, async: true

  @moduletag :playwright

  # Rendered sizes of the shared controls and list on the review fixture.
  @measure """
  () => {
    const box = selector => document.querySelector(selector).getBoundingClientRect()
    const cell = document.querySelector("#items td")

    return {
      button: box("#primary").height,
      table_text: parseFloat(getComputedStyle(cell).fontSize)
    }
  }
  """

  defp open_review(conn) do
    conn
    |> visit("/test/ui-review")
    |> assert_has("body .phx-connected")
  end

  defp compact(conn) do
    evaluate(conn, "document.documentElement.dataset.density = 'compact'")
  end

  defp measure(conn, fun), do: evaluate(conn, @measure, [is_function: true], fun)

  describe "on a mouse pointer" do
    test "comfortable is the default density", %{conn: conn} do
      conn
      |> open_review()
      |> measure(fn sizes ->
        assert sizes["button"] == 32
        assert sizes["table_text"] == 13
      end)
    end

    test "compact tightens controls and table text", %{conn: conn} do
      conn
      |> open_review()
      |> compact()
      |> measure(fn sizes ->
        assert sizes["button"] == 28
        assert sizes["table_text"] == 12
      end)
    end
  end

  describe "on a touch screen" do
    @describetag browser_context_opts: [
                   has_touch: true,
                   is_mobile: true,
                   viewport: %{width: 390, height: 844}
                 ]

    test "controls keep a 44px tap target at either density", %{conn: conn} do
      conn
      |> open_review()
      |> measure(fn sizes ->
        assert sizes["button"] >= 44
      end)
      |> compact()
      |> measure(fn sizes ->
        assert sizes["button"] >= 44
        assert sizes["table_text"] == 12
      end)
    end
  end
end
