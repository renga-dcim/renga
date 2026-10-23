defmodule RengaWeb.QuerySettingsLiveTest do
  use RengaWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Renga.AccountsFixtures
  import Renga.InventoryFixtures

  alias Renga.Jobs

  defp member_conn(conn, organization, role) do
    user = user_fixture()
    organization_membership_fixture(user, organization, %{role: role})

    conn
    |> log_in_user(user)
    |> put_session(:current_organization_id, organization.id)
  end

  test "owners enable and disable each query on its own", %{conn: conn} do
    organization = organization_fixture()
    {:ok, view, _html} = live(member_conn(conn, organization, "owner"), ~p"/settings/queries")

    assert has_element?(view, "#queries-access", "queries.run_sensitive")
    assert has_element?(view, "#query-packages-1-sensitivity", "Sensitive")
    assert has_element?(view, "#query-disk_usage-1-sensitivity", "Inventory")
    assert has_element?(view, "#query-disk_usage-1-status", "Off")

    view |> element("#query-disk_usage-1-toggle") |> render_click()

    assert has_element?(view, "#query-disk_usage-1-status", "On")
    assert has_element?(view, "#query-packages-1-status", "Off")

    allowed = Jobs.get_settings(Renga.Repo.reload!(organization)).allowed_capabilities
    assert "query.disk_usage@1" in allowed
    assert "inventory.collect@1" in allowed

    view |> element("#query-disk_usage-1-toggle", "Disable") |> render_click()
    assert has_element?(view, "#query-disk_usage-1-status", "Off")
  end

  test "others see which queries are on but cannot change them", %{conn: conn} do
    organization = organization_fixture()
    {:ok, view, _html} = live(member_conn(conn, organization, "admin"), ~p"/settings/queries")

    assert has_element?(view, "#query-routes-1-status", "Off")
    refute has_element?(view, "#query-routes-1-toggle")

    # A forged event is refused by the context, not just hidden.
    render_click(view, "toggle", %{"key" => "query.routes@1", "enabled" => "true"})
    assert has_element?(view, "#query-routes-1-status", "Off")

    refute "query.routes@1" in Jobs.get_settings(Renga.Repo.reload!(organization)).allowed_capabilities
  end
end
