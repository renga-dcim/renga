defmodule RengaWeb.BrandTest do
  use RengaWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Renga.AccountsFixtures
  import Renga.InventoryFixtures

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

    test "clips the inverted wall to the rounded tile with its own clip path" do
      html = render_component(&Brand.mark/1, %{variant: :tile, clip_id: "login-tile"})

      assert html |> query("clipPath") |> LazyHTML.attribute("id") == ["login-tile"]
      assert html |> query("svg > g") |> LazyHTML.attribute("clip-path") == ["url(#login-tile)"]
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

  describe "in the app" do
    test "the signed-out header and sign-in card show the logo", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/users/log-in")

      assert has_element?(view, "header a[aria-label='Renga home'] svg[aria-label=Renga]")
      assert has_element?(view, "#login svg g[clip-path]")
      refute has_element?(view, ".hero-server-stack-solid")
    end

    test "the sidebar shows the wordmark", %{conn: conn} do
      user = user_fixture()
      organization = organization_fixture()
      organization_membership_fixture(user, organization)

      conn =
        conn
        |> log_in_user(user)
        |> Plug.Conn.put_session(:current_organization_id, organization.id)

      {:ok, view, _html} = live(conn, ~p"/inbox")

      assert has_element?(view, "#app-sidebar a[aria-label='Renga home'] svg[aria-label=Renga]")
    end
  end
end
