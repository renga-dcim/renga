defmodule RengaWeb.QueryFanOutLiveTest do
  @moduledoc """
  RFD 12 fan-out from the inventory list: "Run query" asks every matching
  host as one batch, whose page shows what each host answered in one table.
  """
  use RengaWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Renga.JobsFixtures

  alias Renga.Accounts
  alias Renga.Assignments
  alias Renga.Jobs
  alias Renga.Jobs.Job
  alias Renga.Roles

  @sockets "query.listening_sockets@1"
  @time "query.time_sync@1"

  setup do
    %{organization: organization, scope: owner, system_scope: system} =
      job_organization_fixture()

    {:ok, _} = Jobs.update_settings(owner, %{allowed_capabilities: [@sockets, @time]})

    member = member_scope(organization, "member")

    {:ok, role} =
      Roles.create_role(owner, %{
        "name" => "Sensitive queries",
        "permissions" => ~w(queries.run queries.run_sensitive)
      })

    {:ok, _} = Assignments.assign(owner, member.membership_id, %{"role" => role.id})

    web = agent_fixture(organization, [@sockets, @time])
    db = agent_fixture(organization, [@sockets, @time])
    old = agent_fixture(organization, [])

    %{
      organization: organization,
      owner: owner,
      system: system,
      runner: Accounts.scope_for_user(member.user, organization.id),
      agents: %{web: web, db: db},
      web: reported_resource_fixture(organization, web, "web-01"),
      db: reported_resource_fixture(organization, db, "db-01"),
      old: reported_resource_fixture(organization, old, "old-01")
    }
  end

  defp conn_for(conn, scope, organization) do
    conn
    |> log_in_user(scope.user)
    |> put_session(:current_organization_id, organization.id)
  end

  defp answer(context, agent, job, result) do
    {:ok, [{_job, token}]} =
      Jobs.lease_jobs(context.system, agent, [Job.capability_key(job)], 1)

    {:ok, _} =
      Jobs.report(context.system, agent, job.id, token, "succeeded", %{"result" => result})
  end

  test "only holders of queries.run see Run query", context do
    {:ok, view, _html} =
      live(conn_for(context.conn, context.owner, context.organization), ~p"/inventory")

    refute has_element?(view, "#run-query")

    {:ok, view, _html} =
      live(conn_for(context.conn, context.runner, context.organization), ~p"/inventory")

    assert has_element?(view, "#run-query")
  end

  test "runs a query across the filtered list and shows each host's answers", context do
    conn = conn_for(context.conn, context.runner, context.organization)
    {:ok, view, _html} = live(conn, ~p"/inventory?#{[kind: "server"]}")

    view |> element("#run-query") |> render_click()
    assert has_element?(view, "#query-fan-out-reach", "2 of 3 matching resources")

    view
    |> form("#query-fan-out-form", capability: @sockets)
    |> render_change()

    assert has_element?(view, "#query-fan-out-form input[name='query[port]']")

    {:error, {:live_redirect, %{to: path}}} =
      view
      |> form("#query-fan-out-form", capability: @sockets, query: %{port: "23"})
      |> render_submit()

    "/activity/queries/" <> batch_id = path
    jobs = Jobs.list_jobs(context.runner, batch_id: batch_id)
    assert length(jobs) == 2
    assert Enum.all?(jobs, &(&1.parameters == %{"port" => 23}))

    web_job = Enum.find(jobs, &(&1.resource_id == context.web.id))
    db_job = Enum.find(jobs, &(&1.resource_id == context.db.id))

    answer(context, context.agents.web, web_job, %{
      "sockets" => [
        %{
          "protocol" => "tcp",
          "address" => "0.0.0.0",
          "port" => 23,
          "process" => "telnetd",
          "pid" => 41
        }
      ],
      "truncated" => false
    })

    {:ok, view, _html} = live(conn, path)

    assert has_element?(view, "#query-batch", "Listening sockets across 2 hosts")
    assert has_element?(view, "#query-batch", "port 23")
    assert has_element?(view, "#query-batch-answered", "1")
    assert has_element?(view, "#query-batch-waiting", "1")
    assert has_element?(view, "#query-batch-row-0", "web-01")
    assert has_element?(view, "#query-batch-row-0", "telnetd")
    refute has_element?(view, "#query-batch-row-1")
    assert has_element?(view, "#query-batch-host-#{db_job.id}-state", "Waiting for agent")

    answer(context, context.agents.db, db_job, %{"sockets" => [], "truncated" => false})
    send(view.pid, :reload)

    assert has_element?(view, "#query-batch-answered", "2")
    assert has_element?(view, "#query-batch-empty", "db-01")
  end

  test "a result without a list reads as a row per host", context do
    {:ok, %{batch_id: batch_id, jobs: jobs}} =
      Jobs.create_batch(context.runner, @time, %{}, [context.web.id])

    [job] = jobs

    answer(context, context.agents.web, job, %{
      "synchronized" => true,
      "daemon" => "chronyd",
      "source" => "time.example.net",
      "stratum" => 2,
      "offset_us" => -12,
      "max_error_us" => 900,
      "estimated_error_us" => 40
    })

    conn = conn_for(context.conn, context.runner, context.organization)
    {:ok, view, _html} = live(conn, ~p"/activity/queries/#{batch_id}")

    assert has_element?(view, "#query-batch", "Time sync across 1 host")
    refute has_element?(view, "#query-batch", "1 hosts")
    assert has_element?(view, "#query-batch-row-0", "web-01")
    assert has_element?(view, "#query-batch-row-0", "chronyd")
    assert has_element?(view, "#query-batch-row-0", "-12 µs")
  end

  test "a reader without the permissions sees the hosts, not the answers", context do
    {:ok, %{batch_id: batch_id, jobs: [job]}} =
      Jobs.create_batch(context.runner, @time, %{}, [context.web.id])

    answer(context, context.agents.web, job, %{
      "synchronized" => true,
      "daemon" => "chronyd",
      "source" => "time.example.net",
      "stratum" => 2,
      "offset_us" => -12,
      "max_error_us" => 900,
      "estimated_error_us" => 40
    })

    conn = conn_for(context.conn, context.owner, context.organization)
    {:ok, view, html} = live(conn, ~p"/activity/queries/#{batch_id}")

    assert has_element?(view, "#query-batch-hidden", "queries.run")
    assert has_element?(view, "#query-batch-host-#{job.id}", "web-01")
    refute has_element?(view, "#query-batch-results")
    refute html =~ "chronyd"
  end

  test "an unknown batch is not found", context do
    conn = conn_for(context.conn, context.runner, context.organization)

    assert_raise Ecto.NoResultsError, fn ->
      live(conn, ~p"/activity/queries/#{Ecto.UUID.generate()}")
    end
  end
end
