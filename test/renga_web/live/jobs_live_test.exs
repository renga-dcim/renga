defmodule RengaWeb.JobsLiveTest do
  use RengaWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Renga.JobsFixtures

  alias Renga.Accounts
  alias Renga.Inventory
  alias Renga.Jobs
  alias Renga.Jobs.Changes
  alias Renga.Repo

  @collect "inventory.collect@1"

  setup %{conn: conn} do
    %{organization: organization, scope: scope, system_scope: system_scope} =
      job_organization_fixture()

    installation_id = Ecto.UUID.generate()
    {:ok, {_key, token}} = Inventory.create_intake_api_key(scope, %{name: "Fleet"})
    {:ok, key} = Inventory.authenticate_intake_api_key(token)

    {:ok, {agent, _lease}} =
      Inventory.record_intake_agent_check_in(
        Accounts.scope_for(organization),
        key,
        installation_id,
        %{capabilities: [@collect]}
      )

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
      resource: resource,
      token: token,
      installation_id: installation_id
    }
  end

  defp post_json(context, path, body) do
    build_conn()
    |> put_req_header("authorization", "Bearer #{context.token}")
    |> put_req_header("x-renga-installation-id", context.installation_id)
    |> put_req_header("content-type", "application/json")
    |> post(path, Jason.encode!(body))
  end

  defp lease_over_http(context) do
    post_json(context, ~p"/api/v1/agent/jobs/lease", %{
      "capabilities" => [@collect],
      "limit" => 1
    })
  end

  defp report_over_http(context, job, token, sequence, type) do
    post_json(context, ~p"/api/v1/agent/jobs/#{job}/events", %{
      "lease_token" => token,
      "sequence" => sequence,
      "type" => type,
      "payload" => %{}
    })
  end

  defp request(%{scope: scope, agent: agent, resource: resource}) do
    {:ok, job} = Jobs.create_job(scope, agent.id, @collect, %{}, resource_id: resource.id)
    job
  end

  defp request_many(%{scope: scope, agent: agent}, count) do
    for _ <- 1..count do
      {:ok, job} = Jobs.create_job(scope, agent.id, @collect, %{})
      job
    end
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
    {:ok, finished} = Jobs.create_job(context.scope, context.agent.id, @collect, %{})
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

  test "loads older jobs and resets the loaded depth when the filter changes", context do
    open = request_many(context, 51)
    {:ok, finished} = Jobs.create_job(context.scope, context.agent.id, @collect, %{})
    {:ok, _finished} = Jobs.cancel_job(context.scope, finished.id)
    {:ok, view, _html} = live(context.conn, ~p"/activity/jobs")

    assert length(job_row_ids(view)) == 50
    assert has_element?(view, "#jobs-load-older")

    view |> element("#jobs-load-older") |> render_click()
    assert length(job_row_ids(view)) == 52
    refute has_element?(view, "#jobs-load-older")

    view |> element("#jobs-filter-open") |> render_click()
    assert length(job_row_ids(view)) == 50
    assert has_element?(view, "#jobs-load-older")

    view |> element("#jobs-load-older") |> render_click()
    assert Enum.sort(job_row_ids(view)) == Enum.sort(Enum.map(open, &"jobs-#{&1.id}"))

    view |> element("#jobs-filter-finished") |> render_click()
    assert job_row_ids(view) == ["jobs-#{finished.id}"]
    refute has_element?(view, "#jobs-load-older")
  end

  test "live transitions preserve the loaded depth", context do
    jobs = request_many(context, 51)
    oldest = List.first(jobs)
    {:ok, view, _html} = live(context.conn, ~p"/activity/jobs?state=open")
    view |> element("#jobs-load-older") |> render_click()
    assert length(job_row_ids(view)) == 51

    {:ok, _cancelled} = Jobs.cancel_job(context.scope, oldest.id)

    assert eventually(fn ->
             length(job_row_ids(view)) == 50 and
               "jobs-#{oldest.id}" not in job_row_ids(view)
           end)

    {:ok, newest} = Jobs.create_job(context.scope, context.agent.id, @collect, %{})

    assert eventually(fn ->
             length(job_row_ids(view)) == 51 and
               "jobs-#{newest.id}" in job_row_ids(view)
           end)
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

  test "follows lease and report requests made through the agent HTTP API", context do
    job = request(context)
    {:ok, view, _html} = live(context.conn, ~p"/activity/jobs/#{job}")

    assert %{"jobs" => [%{"lease_token" => token}]} =
             context |> lease_over_http() |> json_response(200)

    assert eventually(fn ->
             has_element?(view, "#job-panel-status[data-state=leased]", "Picked up")
           end)

    assert %{"job" => %{"state" => "running"}} =
             context |> report_over_http(job, token, 1, "started") |> json_response(200)

    assert eventually(fn ->
             has_element?(view, "#job-panel-status[data-state=running]", "Running")
           end)
  end

  test "an HTTP lease publishes a withdrawn-capability refusal only to its tenant", context do
    job = request(context)
    {:ok, view, _html} = live(context.conn, ~p"/activity/jobs/#{job}")
    other = job_organization_fixture()
    other_organization_id = other.organization.id
    :ok = Changes.subscribe(context.scope)
    :ok = Changes.subscribe(other.scope)

    context.organization
    |> Ecto.Changeset.change(settings: %{"jobs" => %{"allowed_capabilities" => []}})
    |> Repo.update!()

    assert %{"jobs" => []} = context |> lease_over_http() |> json_response(200)
    assert_receive {:jobs_changed, organization_id}
    assert organization_id == context.organization.id
    refute_receive {:jobs_changed, ^other_organization_id}

    assert eventually(fn ->
             has_element?(view, "#job-panel-status[data-state=failed]", "No longer allowed")
           end)
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

    bound = target_binding_fixture(organization, agent)

    {:ok, _job} =
      Jobs.create_system_job(organization.id, agent.id, restart, %{"service" => "sshd"},
        resource_id: bound.resource.id
      )

    {:ok, [{job, token}]} = lease_privileged(system_scope, agent, [restart], bound.private_key)
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

  defp eventually(fun, attempts \\ 40)
  defp eventually(_fun, 0), do: false

  defp eventually(fun, attempts) do
    if fun.() do
      true
    else
      Process.sleep(25)
      eventually(fun, attempts - 1)
    end
  end

  defp job_row_ids(view) do
    view
    |> render()
    |> LazyHTML.from_document()
    |> LazyHTML.query("#jobs-list tr[data-phx-stream]")
    |> LazyHTML.attribute("id")
  end
end
