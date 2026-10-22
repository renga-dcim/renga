defmodule RengaWeb.LimitsLiveTest do
  use RengaWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Renga.AccountsFixtures
  import Renga.InventoryFixtures

  defp member_conn(conn, role) do
    user = user_fixture()
    organization = organization_fixture()
    organization_membership_fixture(user, organization, %{role: role})

    conn =
      conn
      |> log_in_user(user)
      |> put_session(:current_organization_id, organization.id)

    {conn, organization}
  end

  test "owners see each limit, its usage, and whether it is overridden", %{conn: conn} do
    {conn, organization} = member_conn(conn, "owner")

    :ok =
      Renga.Limits.set(
        organization,
        [job_creation_rate: 2_500],
        Renga.DeploymentAudit.operator("test")
      )

    {:ok, view, _html} = live(conn, ~p"/settings/limits")

    assert has_element?(view, "#limit-job_creation_rate-value", "2,500")
    assert has_element?(view, "#limit-job_creation_rate-usage", "0")
    assert has_element?(view, "#limit-job_creation_rate-override")
    refute has_element?(view, "#limits-list form")
  end

  test "shows the deployment default without an override", %{conn: conn} do
    {conn, _organization} = member_conn(conn, "owner")

    {:ok, view, _html} = live(conn, ~p"/settings/limits")

    assert has_element?(view, "#limit-job_creation_rate-value", "10,000")
    refute has_element?(view, "#limit-job_creation_rate-override")
  end

  test "other members do not see limits", %{conn: conn} do
    {conn, _organization} = member_conn(conn, "admin")

    {:ok, view, _html} = live(conn, ~p"/settings/limits")

    assert has_element?(view, "#limits-owners-only")
    refute has_element?(view, "#limits-list")
  end
end
