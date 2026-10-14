defmodule RengaWeb.JobsLiveTest do
  use RengaWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Renga.JobsFixtures

  alias Renga.Jobs

  @collect "inventory.collect@1"

  setup %{conn: conn} do
    %{organization: organization, scope: scope, system_scope: system_scope} =
      job_organization_fixture()

    agent = agent_fixture(organization)
    resource = reported_resource_fixture(organization, agent)

    conn =
      conn
      |> log_in_user(scope.user)
      |> put_session(:current_organization_id, organization.id)

    %{
      conn: conn,
      organization: organization,
      scope: scope,
      system_scope: system_scope,
      agent: agent,
      resource: resource
    }
  end

  defp request(%{scope: scope, agent: agent, resource: resource}) do
    {:ok, job} = Jobs.create_job(scope, agent.id, @collect, %{}, resource_id: resource.id)
    job
  end

  defp run(%{system_scope: system_scope, agent: agent}, type, payload) do
    {:ok, [{job, token}]} = Jobs.lease_jobs(system_scope, agent, [@collect], 1)
    {:ok, _} = Jobs.report(system_scope, agent, job.id, token, "started", %{})
    {:ok, job} = Jobs.report(system_scope, agent, job.id, token, type, payload)
    job
  end

  test "lists jobs with their target and state, and filters by state", context do
    %{conn: conn} = context
    waiting = request(context)
    finished = request(context)
    {:ok, _} = Jobs.cancel_job(context.scope, finished.id)

    {:ok, view, _html} = live(conn, ~p"/activity/jobs")

    assert has_element?(view, "#area-tabs a[aria-current=page]", "Jobs")
    assert has_element?(view, "#jobs-list", "Collect inventory")
    assert has_element?(view, "#jobs-list", "compute-01")
    assert has_element?(view, "#job-#{waiting.id}-state[data-state=queued]", "Waiting for agent")
    assert has_element?(view, "#job-#{finished.id}-state[data-state=cancelled]")

    view |> element("#jobs-filter-open") |> render_click()
    assert_patch(view, ~p"/activity/jobs?state=open")
    assert has_element?(view, "#job-#{waiting.id}-state")
    refute has_element?(view, "#job-#{finished.id}-state")

    view |> element("#jobs-filter-needs_review") |> render_click()
    assert has_element?(view, "#jobs-list", "No job needs review.")
  end

  test "opens a job's detail with its history and cancels it", context do
    %{conn: conn} = context
    job = request(context)

    {:ok, view, _html} = live(conn, ~p"/activity/jobs/#{job}")

    assert has_element?(view, "#job-panel-status[data-state=queued]")
    assert has_element?(view, "#job-panel-facts", @collect)
    assert has_element?(view, "#job-panel-facts", "Observe · safe to retry")
    assert has_element?(view, "#job-history [data-type=created]", context.scope.user.email)

    view |> element("#job-cancel") |> render_click()

    assert has_element?(view, "#job-panel-status[data-state=cancelled]")
    assert has_element?(view, "#job-history [data-type=cancelled]")
    refute has_element?(view, "#job-cancel")
  end

  test "follows a job as the agent reports on it", context do
    %{conn: conn} = context
    job = request(context)
    {:ok, view, _html} = live(conn, ~p"/activity/jobs/#{job}")

    observation_id = Ecto.UUID.generate()
    run(context, "succeeded", %{"result" => %{"observation_id" => observation_id}})
    send(view.pid, :reload)

    assert has_element?(view, "#job-panel-status[data-state=succeeded]")

    assert has_element?(
             view,
             "#job-panel-status",
             "Observation #{String.slice(observation_id, 0, 8)}"
           )

    assert has_element?(view, "#job-history [data-type=succeeded]", context.agent.name)
  end

  test "hides cancel from people who cannot cancel", context do
    %{conn: conn, organization: organization} = context
    job = request(context)
    viewer = member_scope(organization, "viewer")

    conn =
      conn
      |> recycle()
      |> log_in_user(viewer.user)
      |> put_session(:current_organization_id, organization.id)

    {:ok, view, _html} = live(conn, ~p"/activity/jobs/#{job}")

    assert has_element?(view, "#job-panel-status[data-state=queued]")
    refute has_element?(view, "#job-cancel")
    assert render_click(view, "cancel", %{"id" => job.id}) =~ "Only owners and admins"
  end

  test "records what happened to a job that needs review", context do
    %{conn: conn, organization: organization, system_scope: system_scope} = context
    restart = "test.restart@1"

    organization
    |> Ecto.Changeset.change(settings: %{"jobs" => %{"allowed_capabilities" => [restart]}})
    |> Renga.Repo.update!()

    agent = agent_fixture(organization, [restart])

    {:ok, _job} =
      Jobs.create_system_job(organization.id, agent.id, restart, %{"service" => "sshd"})

    {:ok, [{job, token}]} = Jobs.lease_jobs(system_scope, agent, [restart], 1)
    {:ok, _} = Jobs.report(system_scope, agent, job.id, token, "started", %{})
    Jobs.sweep(DateTime.add(DateTime.utc_now(), 120))

    {:ok, view, _html} = live(conn, ~p"/activity/jobs/#{job}?state=needs_review")

    assert has_element?(view, "#job-#{job.id}-state[data-state=uncertain]", "Needs review")
    assert has_element?(view, "#job-panel-status[data-state=uncertain]")
    assert has_element?(view, "#job-history [data-type=uncertain]", "not safe to retry")

    assert view |> form("#job-resolve-form", resolve: %{note: "checked"}) |> render_submit() =~
             "Choose what happened"

    view
    |> form("#job-resolve-form", resolve: %{outcome: "succeeded", note: "Service was up"})
    |> render_submit()

    assert has_element?(view, "#job-panel-status[data-state=succeeded]")
    assert has_element?(view, "#job-history [data-type=resolved]", "Service was up")
    refute has_element?(view, "#job-resolve-form")
  end

  test "job outcomes appear in the Changes feed with their detail", context do
    %{conn: conn} = context
    request(context)
    run(context, "failed", %{"reason" => "collector exited 1"})

    {:ok, view, _html} = live(conn, ~p"/activity")

    assert has_element?(view, "#activity-events", "Inventory collection requested")
    assert has_element?(view, "#activity-events", "Inventory collection failed")
    assert has_element?(view, "#activity-events", "collector exited 1")
    assert has_element?(view, "#activity-events", context.agent.name)
  end
end
