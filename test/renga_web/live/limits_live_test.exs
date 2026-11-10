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

  test "owners see the quota finding at 80 percent without gaining edit controls", %{conn: conn} do
    {conn, organization} = member_conn(conn, "owner")
    scope = Renga.Accounts.scope_for(organization)
    {:ok, _} = Renga.Inventory.create_resource(scope, %{kind: "server", name: "one"})

    :ok = Renga.Limits.set(organization, [resources: 1], Renga.DeploymentAudit.operator("test"))
    {:ok, view, _html} = live(conn, ~p"/settings/limits")
    assert has_element?(view, "#quota-finding-resources", "1 of 1 in use")
    refute has_element?(view, "#limits form")

    finding =
      Renga.Repo.get_by!(Renga.Quotas.Finding,
        organization_id: organization.id,
        name: "resources"
      )

    path = ~p"/inbox?#{[group: "health", finding: "quota:#{finding.id}"]}"
    assert has_element?(view, "#quota-finding-resources a[href='#{path}']")
    {:ok, inbox, _} = live(conn, path)
    assert has_element?(inbox, "#finding-panel", "Organization quota")
    assert has_element?(inbox, "#finding-properties a[href='/settings/limits']")
  end
end
