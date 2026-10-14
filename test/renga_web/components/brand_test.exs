defmodule RengaWeb.BrandTest do
  use RengaWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias RengaWeb.Brand

  defp query(html, selector), do: html |> LazyHTML.from_fragment() |> LazyHTML.query(selector)
  defp count(html, selector), do: html |> query(selector) |> Enum.count()

  describe "mark/1" do
    test "draws the bricks in the accent by default and hides itself from assistive tech" do
      html = render_component(&Brand.mark/1, %{})

      assert html |> query("svg[aria-hidden=true]") |> LazyHTML.attribute("class") == [
               "size-6 text-accent"
             ]

      assert count(html, "svg rect") == 10
    end

    test "draws the inverted wall as its own set of bricks" do
      primary = render_component(&Brand.mark/1, %{})
      inverted = render_component(&Brand.mark/1, %{variant: :inverted})

      assert count(inverted, "svg rect") > count(primary, "svg rect")
    end
  end

  describe "wordmark/1" do
    test "names Renga and puts only the R in the accent" do
      html = render_component(&Brand.wordmark/1, %{})

      assert html |> query("svg[role=img]") |> LazyHTML.attribute("aria-label") == ["Renga"]
      assert count(html, "svg > g.text-accent > rect") == 10
      assert count(html, "svg > rect") > 0
    end

    test "leaves room below the baseline only for the lowercase g" do
      lower = render_component(&Brand.wordmark/1, %{})
      caps = render_component(&Brand.wordmark/1, %{caps: true})

      assert lower |> query("svg") |> LazyHTML.attribute("viewBox") == ["0 0 113 33.2"]
      assert caps |> query("svg") |> LazyHTML.attribute("viewBox") == ["0 0 113 24"]
    end

    test "drops the accent in one tone" do
      html = render_component(&Brand.wordmark/1, %{tone: :one})

      assert count(html, ".text-accent") == 0
    end
  end
end
