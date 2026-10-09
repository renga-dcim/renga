defmodule RengaWeb.AppearanceLiveTest do
  use RengaWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Renga.AccountsFixtures
  import Renga.InventoryFixtures

  alias Renga.Accounts

  setup %{conn: conn} do
    organization = organization_fixture(%{name: "Acme"})
    owner = user_fixture()
    organization_membership_fixture(owner, organization, %{role: "owner"})
    member = user_fixture()
    organization_membership_fixture(member, organization, %{role: "member"})

    %{
      organization: organization,
      owner: owner,
      member: member,
      conn: log_in(conn, member, organization)
    }
  end

  test "choices save to the account and apply at once", %{conn: conn, member: member} do
    {:ok, view, _html} = live(conn, ~p"/settings/appearance")

    assert has_element?(view, "#theme-system[checked]")
    assert has_element?(view, "#accent-default[checked]")
    assert has_element?(view, "#density-comfortable[checked]")
    refute has_element?(view, "#organization-appearance")

    view
    |> form("#appearance-form",
      appearance: %{theme: "dark", accent: "petrol", density: "compact"}
    )
    |> render_change()

    assert_push_event(view, "appearance", %{theme: "dark", accent: "petrol", density: "compact"})
    assert has_element?(view, "#appearance-saved", "Saved")
    assert has_element?(view, "#accent-petrol[checked]")

    assert %{theme: "dark", accent: "petrol", density: "compact"} =
             Accounts.get_user!(member.id)
  end

  test "the page root carries the saved appearance, so nothing flashes", context do
    {:ok, _user} =
      Accounts.update_user_appearance(context.member, %{
        "theme" => "dark",
        "accent" => "iris",
        "density" => "compact"
      })

    html = context.conn |> get(~p"/settings/appearance") |> html_response(200)
    [root] = html |> LazyHTML.from_document() |> LazyHTML.query("html") |> Enum.to_list()

    assert LazyHTML.attribute(root, "data-theme") == ["dark"]
    assert LazyHTML.attribute(root, "data-accent") == ["iris"]
    assert LazyHTML.attribute(root, "data-density") == ["compact"]
    assert LazyHTML.attribute(root, "data-theme-pref") == ["dark"]
  end

  test "the theme button cycles and saves the theme", %{conn: conn, member: member} do
    {:ok, view, _html} = live(conn, ~p"/inbox")

    view |> element("#theme-toggle") |> render_click()
    assert_push_event(view, "appearance", %{theme: "light"})
    assert Accounts.get_user!(member.id).theme == "light"

    view |> element("#theme-toggle") |> render_click()
    assert Accounts.get_user!(member.id).theme == "dark"
  end

  test "owners set the accent members see until they choose", context do
    conn = log_in(build_conn(), context.owner, context.organization)
    {:ok, view, _html} = live(conn, ~p"/settings/appearance")

    view
    |> form("#default-accent-form", organization: %{default_accent: "cobalt"})
    |> render_change()

    assert has_element?(view, "#flash-info", "Cobalt")
    assert_push_event(view, "appearance", %{accent: "cobalt"})

    html = context.conn |> get(~p"/settings/appearance") |> html_response(200)
    [root] = html |> LazyHTML.from_document() |> LazyHTML.query("html") |> Enum.to_list()
    assert LazyHTML.attribute(root, "data-accent") == ["cobalt"]

    # A member cannot change it with a forged event.
    {:ok, member_view, _html} = live(context.conn, ~p"/settings/appearance")

    render_change(member_view, "save_default_accent", %{
      "organization" => %{"default_accent" => "iris"}
    })

    assert has_element?(member_view, "#flash-error", "Only owners")
    assert Accounts.get_organization!(context.organization.id).default_accent == "cobalt"
  end

  test "shared theme control updates the form and survives another preference edit", context do
    {:ok, view, _html} = live(context.conn, ~p"/settings/appearance")
    view |> element("#theme-toggle") |> render_click()
    assert has_element?(view, "#theme-light[checked]")
    refute has_element?(view, "#theme-system[checked]")
    view |> form("#appearance-form", appearance: %{density: "compact"}) |> render_change()
    assert %{theme: "light", density: "compact"} = Accounts.get_user!(context.member.id)
  end

  test "authenticated reauthentication page supports the shared theme control", context do
    {:ok, view, _html} = live(context.conn, ~p"/users/log-in")
    view |> element("#theme-toggle") |> render_click()
    assert Accounts.get_user!(context.member.id).theme == "light"
  end

  defp log_in(conn, user, organization) do
    conn
    |> log_in_user(user)
    |> put_session(:current_organization_id, organization.id)
  end
end
