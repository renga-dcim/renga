defmodule RengaWeb.Api.V1.JobControllerTest do
  use RengaWeb.ConnCase, async: true

  import Renga.JobsFixtures

  alias Renga.Accounts
  alias Renga.Inventory
  alias Renga.Jobs
  alias Renga.Repo

  @collect "inventory.collect@1"
  @restart "test.restart@1"

  setup do
    %{organization: organization, scope: scope} = context = job_organization_fixture()
    installation_id = Ecto.UUID.generate()

    {:ok, {_key, token}} = Inventory.create_intake_api_key(scope, %{name: "Fleet"})
    {:ok, key} = Inventory.authenticate_intake_api_key(token)

    {:ok, {agent, _lease}} =
      Inventory.record_intake_agent_check_in(
        Accounts.scope_for(organization),
        key,
        installation_id,
        %{capabilities: [@collect, @restart]}
      )

    Map.merge(context, %{agent: agent, token: token, installation_id: installation_id})
  end

  defp post_json(context, path, body) do
    build_conn()
    |> put_req_header("authorization", "Bearer #{context.token}")
    |> put_req_header("x-renga-installation-id", context.installation_id)
    |> put_req_header("content-type", "application/json")
    |> post(path, Jason.encode!(body))
  end

  defp lease(context, body \\ %{"capabilities" => [@collect]}),
    do: post_json(context, ~p"/api/v1/agent/jobs/lease", body)

  defp report(context, job_id, lease_token, sequence, type, payload \\ %{}) do
    post_json(context, ~p"/api/v1/agent/jobs/#{job_id}/events", %{
      "lease_token" => lease_token,
      "sequence" => sequence,
      "type" => type,
      "payload" => payload
    })
  end

  defp queue_job(%{scope: scope, agent: agent}) do
    {:ok, job} = Jobs.create_job(scope, agent.id, @collect, %{})
    job
  end

  defp leased(context) do
    job = queue_job(context)
    %{"jobs" => [%{"lease_token" => token}]} = json_response(lease(context), 200)
    {job, token}
  end

  describe "POST /api/v1/agent/jobs/lease" do
    test "leases queued jobs with a fresh token and a 60 second lease", context do
      job = queue_job(context)

      assert %{"jobs" => [leased]} = json_response(lease(context), 200)

      assert %{
               "id" => id,
               "capability" => @collect,
               "parameters" => %{},
               "attempt" => 1,
               "lease_token" => "" <> _,
               "lease_expires_at" => expires_at,
               "timeout_ms" => 300_000,
               "output_limit_bytes" => 65_536
             } = leased

      assert id == job.id
      {:ok, expires_at, 0} = DateTime.from_iso8601(expires_at)
      assert_in_delta DateTime.diff(expires_at, DateTime.utc_now()), 60, 2

      # Leased jobs are not handed out twice.
      assert %{"jobs" => []} = json_response(lease(context), 200)
    end

    test "leases only the capabilities the agent will run now, up to the limit", context do
      for _ <- 1..3, do: queue_job(context)

      assert %{"jobs" => []} =
               json_response(lease(context, %{"capabilities" => ["other.thing@1"]}), 200)

      assert %{"jobs" => [_, _]} =
               json_response(lease(context, %{"capabilities" => [@collect], "limit" => 2}), 200)
    end

    test "never leases jobs beyond observe over the shared intake key", context do
      context.organization
      |> Ecto.Changeset.change(settings: %{"jobs" => %{"allowed_capabilities" => [@restart]}})
      |> Repo.update!()

      {:ok, _job} =
        Jobs.create_system_job(context.organization.id, context.agent.id, @restart, %{
          "service" => "nginx"
        })

      assert %{"jobs" => []} =
               json_response(lease(context, %{"capabilities" => [@restart]}), 200)
    end

    test "validates the request", context do
      for body <- [
            %{},
            %{"capabilities" => "inventory.collect@1"},
            %{"capabilities" => [1]},
            %{"capabilities" => [@collect], "limit" => 0},
            %{"capabilities" => [@collect], "limit" => 11}
          ] do
        assert %{"status" => "rejected", "errors" => [_ | _]} =
                 json_response(lease(context, body), 422)
      end
    end

    test "requires a registered, active agent", context do
      unknown = %{context | installation_id: Ecto.UUID.generate()}

      assert %{"errors" => [%{"path" => "installation_id"}]} =
               json_response(lease(unknown), 409)

      context.agent |> Ecto.Changeset.change(status: "disabled") |> Repo.update!()

      assert %{"errors" => [%{"path" => "installation_id"}]} = json_response(lease(context), 403)
    end

    test "requires intake authentication" do
      conn = post(build_conn(), ~p"/api/v1/agent/jobs/lease", %{})
      assert json_response(conn, 401)
    end
  end

  describe "POST /api/v1/agent/jobs/:id/events" do
    test "runs a job to success and extends the lease on every report", context do
      {job, token} = leased(context)

      assert %{"status" => "accepted", "job" => %{"state" => "running"}} =
               json_response(report(context, job.id, token, 1, "started"), 200)

      assert %{"cancel_requested" => false, "job" => %{"lease_expires_at" => "" <> _}} =
               json_response(
                 report(context, job.id, token, 2, "progress", %{"step" => "dmi"}),
                 200
               )

      result = %{"result" => %{"observation_id" => Ecto.UUID.generate()}}

      assert %{"job" => %{"state" => "succeeded", "lease_expires_at" => nil}} =
               json_response(report(context, job.id, token, 3, "succeeded", result), 200)

      assert %{state: "succeeded"} = Jobs.get_job!(context.scope, job.id)
    end

    test "records a retried post once and replays a lost final response", context do
      {job, token} = leased(context)
      json_response(report(context, job.id, token, 1, "started"), 200)

      for _ <- 1..2 do
        assert %{"job" => %{"state" => "failed"}} =
                 json_response(
                   report(context, job.id, token, 2, "failed", %{"reason" => "boom"}),
                   200
                 )
      end

      types = context.scope |> Jobs.list_events(job) |> Enum.map(& &1.type)
      assert types == ~w(created leased started failed)
    end

    test "tells the agent when cancellation was requested", context do
      {job, token} = leased(context)
      {:ok, _job} = Jobs.cancel_job(context.scope, job.id)

      assert %{"cancel_requested" => true} =
               json_response(report(context, job.id, token, 1, "started"), 200)

      assert %{"job" => %{"state" => "cancelled"}} =
               json_response(report(context, job.id, token, 2, "cancelled"), 200)
    end

    test "rejects a token that does not hold the lease", context do
      {job, _token} = leased(context)

      assert %{"errors" => [%{"path" => "lease_token"}]} =
               json_response(report(context, job.id, "not-the-token", 1, "started"), 409)
    end

    test "rejects reused or stale sequences and transitions out of order", context do
      {job, token} = leased(context)

      assert %{"errors" => [%{"path" => "type"}]} =
               json_response(report(context, job.id, token, 1, "progress"), 409)

      json_response(report(context, job.id, token, 2, "started"), 200)

      assert %{"errors" => [%{"path" => "sequence"}]} =
               json_response(report(context, job.id, token, 2, "progress"), 409)

      assert %{"errors" => [%{"path" => "sequence"}]} =
               json_response(report(context, job.id, token, 1, "progress"), 409)
    end

    test "checks results against the capability", context do
      {job, token} = leased(context)
      json_response(report(context, job.id, token, 1, "started"), 200)

      assert %{"errors" => [%{"path" => "payload.result.observation_id"} | _]} =
               json_response(
                 report(context, job.id, token, 2, "succeeded", %{"result" => %{}}),
                 422
               )

      assert %{"errors" => [%{"path" => "payload.reason"}]} =
               json_response(report(context, job.id, token, 3, "failed"), 422)
    end

    test "rejects output beyond the job's limit", context do
      {job, token} = leased(context)
      json_response(report(context, job.id, token, 1, "started"), 200)
      big = %{"chunk" => String.duplicate("x", 70_000)}

      assert %{"errors" => [%{"path" => "payload"}]} =
               json_response(report(context, job.id, token, 2, "output", big), 413)
    end

    test "validates the request and the job", context do
      {job, token} = leased(context)

      for {sequence, type, payload} <- [{0, "started", %{}}, {1, "done", %{}}, {1, "started", []}] do
        assert %{"status" => "rejected"} =
                 json_response(report(context, job.id, token, sequence, type, payload), 422)
      end

      assert %{"errors" => [%{"path" => "id"}]} =
               json_response(report(context, Ecto.UUID.generate(), token, 1, "started"), 404)
    end

    test "never touches another organization's job", context do
      {job, token} = leased(context)
      other = job_organization_fixture()
      {:ok, {_key, other_token}} = Inventory.create_intake_api_key(other.scope, %{name: "Other"})

      assert %{"errors" => [%{"path" => "installation_id"}]} =
               json_response(
                 report(%{context | token: other_token}, job.id, token, 1, "started"),
                 409
               )

      assert %{state: "leased"} = Jobs.get_job!(context.scope, job.id)
    end
  end
end
