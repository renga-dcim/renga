defmodule RengaWeb.ResourceCollectLiveTest do
  use RengaWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Renga.JobsFixtures

  alias Renga.Inventory
  alias Renga.Jobs

  @collect "inventory.collect@1"

  setup %{conn: conn} do
    %{organization: organization, scope: scope, system_scope: system_scope} =
      job_organization_fixture()

    agent = agent_fixture(organization)
    resource = reported_resource_fixture(organization, agent)

    %{
      conn: sign_in(conn, scope.user, organization),
      organization: organization,
      scope: scope,
      system_scope: system_scope,
      agent: agent,
      resource: resource
    }
  end

  defp sign_in(conn, user, organization) do
    conn
    |> log_in_user(user)
    |> put_session(:current_organization_id, organization.id)
  end

  defp lease_and_report(%{system_scope: system_scope, agent: agent}, reports) do
    {:ok, [{job, token}]} = Jobs.lease_jobs(system_scope, agent, [@collect], 1)

    for {type, payload} <- reports do
      {:ok, _} = Jobs.report(system_scope, agent, job.id, token, type, payload)
    end

    {job, token}
  end

  test "requests a collection and follows it to its outcome", context do
    %{conn: conn, resource: resource} = context
    {:ok, view, _html} = live(conn, ~p"/inventory/#{resource}")

    assert has_element?(view, "#resource-agent", context.agent.name)
    assert has_element?(view, "#resource-agent", "accepts")
    refute has_element?(view, "#collect-now[aria-disabled]")
    refute has_element?(view, "#collect-notice")

    view |> element("#collect-now") |> render_click()

    assert has_element?(view, "#collect-notice[data-state=queued]", "Waiting for the agent")
    assert has_element?(view, "#collect-now[aria-disabled=true]")
    assert has_element?(view, "#collect-unavailable", "already in progress")
    assert [job] = Jobs.list_jobs(context.scope, resource_id: resource.id)
    assert has_element?(view, ~s|#collect-notice-job[href="/activity/jobs/#{job.id}"]|)

    {job, token} = lease_and_report(context, [{"started", %{}}])
    send(view.pid, :reload)
    assert has_element?(view, "#collect-notice[data-state=running]", "Collecting inventory")

    {:ok, _} =
      Jobs.report(context.system_scope, context.agent, job.id, token, "succeeded", %{
        "result" => %{"observation_id" => Ecto.UUID.generate()}
      })

    send(view.pid, :reload)
    assert has_element?(view, "#collect-notice[data-state=succeeded]")
    refute has_element?(view, "#collect-now[aria-disabled]")
    assert has_element?(view, "#recent-activity", "Inventory collection requested")
  end

  test "shows how a collection ended and lets people dismiss it", context do
    %{conn: conn, scope: scope, agent: agent, resource: resource} = context
    {:ok, _job} = Jobs.create_job(scope, agent.id, @collect, %{}, resource_id: resource.id)
    observation_id = Ecto.UUID.generate()

    lease_and_report(context, [
      {"started", %{}},
      {"succeeded", %{"result" => %{"observation_id" => observation_id}}}
    ])

    {:ok, view, _html} = live(conn, ~p"/inventory/#{resource}")

    assert has_element?(
             view,
             "#collect-notice[data-state=succeeded]",
             "Inventory collection succeeded"
           )

    assert has_element?(view, "#collect-notice", String.slice(observation_id, 0, 8))
    refute has_element?(view, "#collect-now[aria-disabled]")
    assert has_element?(view, "#recent-activity", "Inventory collection succeeded")

    view |> element("#collect-notice-dismiss") |> render_click()
    refute has_element?(view, "#collect-notice")
  end

  test "a failed collection explains why", context do
    %{conn: conn, scope: scope, agent: agent, resource: resource} = context
    {:ok, _job} = Jobs.create_job(scope, agent.id, @collect, %{}, resource_id: resource.id)
    lease_and_report(context, [{"started", %{}}, {"failed", %{"reason" => "collector exited 1"}}])

    {:ok, view, _html} = live(conn, ~p"/inventory/#{resource}")

    assert has_element?(
             view,
             "#collect-notice[data-state=failed][role=alert]",
             "collector exited 1"
           )
  end

  test "cancels a waiting collection", context do
    %{conn: conn, resource: resource} = context
    {:ok, view, _html} = live(conn, ~p"/inventory/#{resource}")

    view |> element("#collect-now") |> render_click()
    view |> element("#collect-notice-cancel") |> render_click()

    assert has_element?(view, "#collect-notice[data-state=cancelled]")
    refute has_element?(view, "#collect-now[aria-disabled]")
  end

  test "explains why a person or agent cannot collect", context do
    %{conn: conn, organization: organization, resource: resource} = context
    member = member_scope(organization, "member")

    {:ok, view, _html} =
      conn |> recycle() |> sign_in(member.user, organization) |> live(~p"/inventory/#{resource}")

    assert has_element?(view, "#collect-now[aria-disabled=true]")
    assert has_element?(view, "#collect-unavailable", "Only owners and admins")
    assert render_click(view, "collect", %{}) =~ "Only owners and admins"
    assert Jobs.list_jobs(context.scope) == []

    old_agent = agent_fixture(organization, ["host.inventory"])
    old_resource = reported_resource_fixture(organization, old_agent, "edge-legacy-01")

    {:ok, view, _html} = live(conn, ~p"/inventory/#{old_resource}")
    assert has_element?(view, "#collect-unavailable", "doesn't accept on-demand collection")
    assert has_element?(view, "#resource-agent", "doesn't accept on-demand collection")
  end

  test "resources without an agent show no Collect now", context do
    {:ok, resource} =
      Inventory.create_resource(context.scope, %{kind: "server", name: "manual-01"})

    {:ok, view, _html} = live(context.conn, ~p"/inventory/#{resource}")

    refute has_element?(view, "#collect-now")
    refute has_element?(view, "#resource-agent")
  end
end
