defmodule RengaWeb.ResourceQueriesLiveTest do
  @moduledoc """
  A host's Queries tab (RFD 12): which queries can run here and why not,
  running one from a form built from its schema, and reading its result only
  with the permissions it needs.
  """
  use RengaWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Renga.JobsFixtures

  alias Renga.Accounts
  alias Renga.Assignments
  alias Renga.Jobs
  alias Renga.Roles

  @disk "query.disk_usage@1"
  @sockets "query.listening_sockets@1"
  @packages "query.packages@1"
  @sql "query.sql@1"

  setup do
    %{organization: organization, scope: owner, system_scope: system} =
      job_organization_fixture()

    agent = agent_fixture(organization, ["host.inventory", @disk, @sockets, @packages, @sql])
    resource = reported_resource_fixture(organization, agent)
    {:ok, _} = Jobs.update_settings(owner, %{allowed_capabilities: [@disk, @sockets]})

    member = member_scope(organization, "member")
    grant(owner, member, ~w(queries.run))

    %{
      organization: organization,
      owner: owner,
      system: system,
      agent: agent,
      resource: resource,
      runner: Accounts.scope_for_user(member.user, organization.id)
    }
  end

  defp grant(owner, scope, permissions) do
    {:ok, role} =
      Roles.create_role(owner, %{
        "name" => "Queries #{System.unique_integer([:positive])}",
        "permissions" => permissions
      })

    {:ok, _} = Assignments.assign(owner, scope.membership_id, %{"role" => role.id})
  end

  defp conn_for(conn, scope, organization) do
    conn
    |> log_in_user(scope.user)
    |> put_session(:current_organization_id, organization.id)
  end

  defp contacted(agent, at) do
    {:ok, _agent} =
      Renga.Inventory.Agent
      |> Renga.Repo.get!(agent.id)
      |> Ecto.Changeset.change(last_contacted_at: at)
      |> Renga.Repo.update()
  end

  defp claim_resource(context, agent) do
    scope = Accounts.scope_for(context.organization)

    {:ok, observation} =
      Renga.Inventory.create_observation(scope, agent.source_id, %{
        observation_id: "report-#{System.unique_integer([:positive])}",
        observed_at: Renga.Time.utc_now_ms(),
        payload: %{"hostname" => context.resource.name}
      })

    {:ok, _claim} =
      Renga.Inventory.create_resource_identifier_claim(scope, agent.source_id, observation.id, %{
        resource_id: context.resource.id,
        kind: "hostname",
        value: context.resource.name,
        confidence: 100
      })
  end

  defp succeed(context, job, result) do
    {:ok, [{_job, token}]} =
      Jobs.lease_jobs(context.system, context.agent, [Renga.Jobs.Job.capability_key(job)], 1)

    {:ok, _} =
      Jobs.report(context.system, context.agent, job.id, token, "succeeded", %{"result" => result})
  end

  test "servers have a Queries tab; other kinds don't", context do
    conn = conn_for(context.conn, context.runner, context.organization)

    {:ok, view, _html} = live(conn, ~p"/inventory/#{context.resource}")
    assert has_element?(view, ~s|a[href="/inventory/#{context.resource.id}/queries"]|, "Queries")

    {:ok, switch} =
      Renga.Inventory.create_resource(Accounts.scope_for(context.organization), %{
        kind: "switch",
        name: "leaf-01",
        lifecycle_state: "active"
      })

    {:ok, view, _html} = live(conn, ~p"/inventory/#{switch}")
    refute has_element?(view, ~s|a[href="/inventory/#{switch.id}/queries"]|)

    # The tab is hidden, and its URL refuses too.
    assert {:error, {:live_redirect, %{to: to}}} = live(conn, ~p"/inventory/#{switch}/queries")
    assert to == ~p"/inventory/#{switch}"
  end

  test "a run goes to the agent heard from most recently when it is sent", context do
    newer = agent_fixture(context.organization, ["host.inventory", @disk])
    claim_resource(context, newer)
    contacted(context.agent, ~U[2026-01-01 00:00:02.000000Z])
    contacted(newer, ~U[2026-01-01 00:00:01.000000Z])
    conn = conn_for(context.conn, context.runner, context.organization)

    {:ok, view, _html} = live(conn, ~p"/inventory/#{context.resource}/queries")
    view |> element("#query-disk_usage-run") |> render_click()

    # The other agent checks in after the panel opened.
    contacted(newer, ~U[2026-01-01 00:00:03.000000Z])
    view |> form("#query-form") |> render_submit()

    assert [%{agent_id: agent_id}] =
             Jobs.list_jobs(context.runner, resource_id: context.resource.id)

    assert agent_id == newer.id
  end

  test "says why each query can or can't run here", context do
    conn = conn_for(context.conn, context.runner, context.organization)

    {:ok, view, _html} = live(conn, ~p"/inventory/#{context.resource}/queries")

    assert has_element?(view, "#query-disk_usage-status", "Ready")
    assert has_element?(view, "#query-disk_usage-run")
    assert has_element?(view, "#query-listening_sockets-sensitivity", "Sensitive")
    assert has_element?(view, "#query-listening_sockets-status", "Needs queries.run_sensitive")
    refute has_element?(view, "#query-listening_sockets-run")
    assert has_element?(view, "#query-packages-status", "Off in this organization")
    assert has_element?(view, "#query-routes-status", "Off in this organization")
  end

  test "an owner without the explicit permissions can't run one", context do
    conn = conn_for(context.conn, context.owner, context.organization)

    {:ok, view, _html} = live(conn, ~p"/inventory/#{context.resource}/queries")

    assert has_element?(view, "#query-disk_usage-status", "Needs queries.run")
    refute has_element?(view, "#query-disk_usage-run")
  end

  test "runs a query and shows its result when the agent reports", context do
    grant(context.owner, context.runner, ~w(queries.run_sensitive))
    runner = Accounts.scope_for_user(context.runner.user, context.organization.id)
    conn = conn_for(context.conn, runner, context.organization)

    {:ok, view, _html} = live(conn, ~p"/inventory/#{context.resource}/queries")

    view |> element("#query-listening_sockets-run") |> render_click()
    assert has_element?(view, "#query-form input[type=number][name='query[port]']")

    view |> form("#query-form", query: %{port: "70000"}) |> render_submit()
    assert has_element?(view, "#query-form", "must be at most 65535")

    view |> form("#query-form", query: %{port: "22"}) |> render_submit()

    [job] = Jobs.list_jobs(runner, resource_id: context.resource.id)
    assert job.parameters == %{"port" => 22}
    assert_patch(view, ~p"/inventory/#{context.resource}/queries?#{[run: job.id]}")
    assert has_element?(view, "#query-result-state", "Waiting for agent")
    assert has_element?(view, "#query-result-heading", "port 22")
    assert has_element?(view, "#query-run-#{job.id}", "you")

    succeed(context, job, %{
      "sockets" => [
        %{
          "protocol" => "tcp",
          "address" => "0.0.0.0",
          "port" => 22,
          "process" => "sshd",
          "pid" => 812
        }
      ],
      "truncated" => true
    })

    # The page re-reads shortly after the jobs change.
    send(view.pid, :reload)

    assert has_element?(view, "#query-result-state", "Succeeded")
    assert has_element?(view, "#query-result-sockets-0", "sshd")
    assert has_element?(view, "#query-result-truncated")
    assert has_element?(view, "#query-run-#{job.id}", "1 listening socket")
  end

  test "renders scalar fields and byte sizes from the schema", context do
    {:ok, job} =
      Jobs.create_job(context.runner, context.agent.id, @disk, %{},
        resource_id: context.resource.id
      )

    succeed(context, job, %{
      "filesystems" => [
        %{
          "mount_point" => "/",
          "device" => "/dev/sda1",
          "fs_type" => "ext4",
          "size_bytes" => 107_374_182_400,
          "used_bytes" => 1536,
          "available_bytes" => 512,
          "inodes_total" => nil,
          "inodes_used" => nil
        }
      ],
      "truncated" => false
    })

    conn = conn_for(context.conn, context.runner, context.organization)
    {:ok, view, _html} = live(conn, ~p"/inventory/#{context.resource}/queries?run=#{job.id}")

    assert has_element?(view, "#query-result-filesystems-0", "100.0 GiB")
    assert has_element?(view, "#query-result-filesystems-0", "1.5 KiB")
    assert has_element?(view, "#query-result-filesystems-0", "512 B")
    assert has_element?(view, "#query-result th", "FS type")
    assert has_element?(view, "#query-result th", "Available")
    refute has_element?(view, "#query-result-truncated")
  end

  test "reads an osquery SQL result as a table of its columns", context do
    {:ok, _} = Jobs.update_settings(context.owner, %{allowed_capabilities: [@sql]})
    grant(context.owner, context.runner, ~w(queries.run_sensitive))
    runner = Accounts.scope_for_user(context.runner.user, context.organization.id)

    {:ok, job} =
      Jobs.create_job(
        runner,
        context.agent.id,
        @sql,
        %{"sql" => "SELECT name, pid, path FROM processes"},
        resource_id: context.resource.id
      )

    succeed(context, job, %{
      "columns" => ["name", "pid", "path", "_bytes", ""],
      "rows" => [
        ["sshd", "812", "/usr/sbin/sshd", "1", ""],
        ["chronyd", "640", "/usr/sbin/chronyd", "2", ""]
      ],
      "truncated" => false
    })

    conn = conn_for(context.conn, runner, context.organization)
    {:ok, view, _html} = live(conn, ~p"/inventory/#{context.resource}/queries?run=#{job.id}")

    assert has_element?(view, "#query-result th", "PID")
    assert has_element?(view, "#query-result th", "Path")
    assert has_element?(view, "#query-result-rows-0 td:nth-child(2)", "812")
    assert has_element?(view, "#query-result-rows-1 td:nth-child(3)", "/usr/sbin/chronyd")
    refute has_element?(view, "#query-result-fields")
  end

  test "a reader without the permissions sees who ran it, not what it found", context do
    {:ok, job} =
      Jobs.create_job(context.runner, context.agent.id, @disk, %{},
        resource_id: context.resource.id
      )

    succeed(context, job, %{"filesystems" => [], "truncated" => false})

    conn = conn_for(context.conn, context.owner, context.organization)
    {:ok, view, html} = live(conn, ~p"/inventory/#{context.resource}/queries?run=#{job.id}")

    assert has_element?(view, "#query-run-#{job.id}", "Result withheld")
    assert has_element?(view, "#query-result-hidden", "queries.run")
    assert has_element?(view, "#query-result-meta", context.runner.user.email)
    refute has_element?(view, "#query-result-filesystems")
    refute html =~ "0 filesystems"
  end

  test "a run from another resource isn't shown here", context do
    other = reported_resource_fixture(context.organization, context.agent, "compute-02")

    {:ok, job} =
      Jobs.create_job(context.runner, context.agent.id, @disk, %{}, resource_id: other.id)

    conn = conn_for(context.conn, context.runner, context.organization)
    path = ~p"/inventory/#{context.resource}/queries"

    assert {:error, {:live_redirect, %{to: ^path}}} =
             live(conn, ~p"/inventory/#{context.resource}/queries?run=#{job.id}")
  end
end
