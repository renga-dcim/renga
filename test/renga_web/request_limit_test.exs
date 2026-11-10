defmodule RengaWeb.RequestLimitTest do
  use RengaWeb.ConnCase, async: true
  import Phoenix.LiveViewTest
  import Renga.JobsFixtures
  alias Renga.Limits

  setup %{conn: conn} do
    %{organization: organization, scope: scope} = job_organization_fixture()

    conn =
      conn |> log_in_user(scope.user) |> put_session(:current_organization_id, organization.id)

    %{conn: conn, organization: organization, scope: scope}
  end

  test "HTTP returns 429 and Retry-After without affecting other organizations", %{
    conn: conn,
    organization: organization
  } do
    :ok = Limits.set(organization, [http_user_rate: 0], Renga.DeploymentAudit.operator("test"))
    response = get(conn, ~p"/settings/limits")
    assert response.status == 429
    assert [seconds] = get_resp_header(response, "retry-after")
    assert String.to_integer(seconds) in 1..60
  end

  test "a rejected LiveView event does not run its handler and can be retried", %{
    conn: conn,
    organization: organization,
    scope: scope
  } do
    {:ok, view, _} = live(conn, ~p"/settings/appearance")
    :ok = Limits.set(organization, [live_user_rate: 0], Renga.DeploymentAudit.operator("test"))

    view |> form("#appearance-form", appearance: %{theme: "dark"}) |> render_change()
    assert has_element?(view, "#flash-error", "Retry in")
    refute Renga.Repo.reload!(scope.user).theme == "dark"

    :ok = Limits.clear(organization, :live_user_rate, Renga.DeploymentAudit.operator("test"))
    view |> form("#appearance-form", appearance: %{theme: "dark"}) |> render_change()
    assert Renga.Repo.reload!(scope.user).theme == "dark"
  end

  test "a rejected navigation cannot run handle_params", %{conn: conn, organization: organization} do
    {:ok, view, _} = live(conn, ~p"/inventory")

    :ok =
      Limits.set(
        organization,
        [live_organization_rate: 0],
        Renga.DeploymentAudit.operator("test")
      )

    render_patch(view, ~p"/inventory?q=blocked")
    assert has_element?(view, "#flash-error", "Retry in")
    refute has_element?(view, "input[name=q][value=blocked]")
  end

  test "a rejected connected mount ends at a retryable 429 instead of rendering uninitialized assigns",
       %{conn: conn, organization: organization} do
    :ok = Limits.set(organization, [live_user_rate: 0], Renga.DeploymentAudit.operator("test"))
    assert {:error, {:redirect, %{to: path}}} = live(conn, ~p"/inventory")
    assert path =~ "/requests/throttled?retry_after="
    assert get(conn, path).status == 429
  end
end
