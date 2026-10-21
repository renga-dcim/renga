defmodule RengaWeb.Api.V1.JobControllerTest do
  use RengaWeb.ConnCase, async: true

  import Renga.JobsFixtures

  alias Renga.Accounts
  alias Renga.Inventory
  alias Renga.Jobs
  alias Renga.Repo
  alias RengaWeb.Api.V1.JobController

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

    Map.merge(context, %{
      agent: agent,
      intake_api_key: key,
      token: token,
      installation_id: installation_id
    })
  end

  defp post_json(context, path, body) do
    build_conn()
    |> put_req_header("authorization", "Bearer #{context.token}")
    |> put_req_header("x-renga-installation-id", context.installation_id)
    |> put_req_header("content-type", "application/json")
    |> post(path, Jason.encode!(body))
  end

  defp authenticated_conn(context) do
    build_conn()
    |> Plug.Conn.assign(:current_scope, context.system_scope)
    |> Plug.Conn.assign(:current_intake_api_key, context.intake_api_key)
    |> Plug.Conn.assign(:current_installation_id, context.installation_id)
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
    %{"jobs" => [%{"lease_token" => token}]} = valid_api_response(lease(context), 200)
    {job, token}
  end

  describe "POST /api/v1/agent/jobs/lease" do
    test "leases queued jobs with a fresh token and a 60 second lease", context do
      job = queue_job(context)

      assert %{"jobs" => [leased]} = valid_api_response(lease(context), 200)

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
      assert %{"jobs" => []} = valid_api_response(lease(context), 200)
    end

    test "leases only the capabilities the agent will run now, up to the limit", context do
      for _ <- 1..3, do: queue_job(context)

      assert %{"jobs" => []} =
               valid_api_response(lease(context, %{"capabilities" => ["other.thing@1"]}), 200)

      assert %{"jobs" => [_, _]} =
               valid_api_response(
                 lease(context, %{"capabilities" => [@collect], "limit" => 2}),
                 200
               )
    end

    test "never leases jobs beyond observe over the shared intake key", context do
      context.organization
      |> Ecto.Changeset.change(settings: %{"jobs" => %{"allowed_capabilities" => [@restart]}})
      |> Repo.update!()

      %{resource: resource} = target_binding_fixture(context.organization, context.agent)

      {:ok, job} =
        Jobs.create_system_job(
          context.organization.id,
          context.agent.id,
          @restart,
          %{"service" => "nginx"},
          resource_id: resource.id
        )

      assert %{"jobs" => [], "offers" => [offer]} =
               valid_api_response(lease(context, %{"capabilities" => [@restart]}), 200)

      assert offer["job_id"] == job.id
      refute Map.has_key?(offer, "parameters")
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
                 valid_api_response(lease(context, body), 422)
      end
    end

    test "requires a registered, active agent", context do
      unknown = %{context | installation_id: Ecto.UUID.generate()}

      assert %{"errors" => [%{"path" => "installation_id"}]} =
               valid_api_response(lease(unknown), 409)

      context.agent |> Ecto.Changeset.change(status: "disabled") |> Repo.update!()

      assert %{"errors" => [%{"path" => "installation_id"}]} =
               valid_api_response(lease(context), 403)
    end

    test "requires intake authentication" do
      conn = post(build_conn(), ~p"/api/v1/agent/jobs/lease", %{})
      assert valid_api_response(conn, 401)
    end

    test "rejects a key revoked after authentication without leasing", context do
      job = queue_job(context)
      {:ok, _key} = Inventory.revoke_intake_api_key(context.scope, context.intake_api_key.id)

      conn =
        JobController.lease(authenticated_conn(context), %{"capabilities" => [@collect]})

      assert %{"errors" => [%{"path" => "authorization"}]} =
               valid_api_response(conn, 401, "leaseAgentJobs")

      assert %{state: "queued"} = Jobs.get_job!(context.scope, job.id)
    end

    test "rejects an organization disabled after authentication without leasing", context do
      job = queue_job(context)

      {:ok, _organization} =
        Accounts.update_organization(context.organization, %{status: "disabled"})

      conn =
        JobController.lease(authenticated_conn(context), %{"capabilities" => [@collect]})

      assert %{"errors" => [%{"path" => "authorization"}]} =
               valid_api_response(conn, 401, "leaseAgentJobs")

      assert %{state: "queued"} = Repo.get!(Renga.Jobs.Job, job.id)
    end
  end

  describe "POST /api/v1/agent/jobs/:id/events" do
    test "runs a job to success and extends the lease on every report", context do
      {job, token} = leased(context)

      assert %{"status" => "accepted", "job" => %{"state" => "running"}} =
               valid_api_response(report(context, job.id, token, 1, "started"), 200)

      assert %{"cancel_requested" => false, "job" => %{"lease_expires_at" => "" <> _}} =
               valid_api_response(
                 report(context, job.id, token, 2, "progress", %{"step" => "dmi"}),
                 200
               )

      result = %{"result" => %{"observation_id" => Ecto.UUID.generate()}}

      assert %{"job" => %{"state" => "succeeded", "lease_expires_at" => nil}} =
               valid_api_response(report(context, job.id, token, 3, "succeeded", result), 200)

      assert %{state: "succeeded"} = Jobs.get_job!(context.scope, job.id)
    end

    test "records a retried post once and replays a lost final response", context do
      {job, token} = leased(context)

      # Work reports carry opaque payloads, even keys that mean something on
      # final reports, and a retry is matched by sequence, not payload.
      for payload <- [%{"result" => 1, "reason" => nil}, %{"result" => [], "reason" => false}] do
        valid_api_response(report(context, job.id, token, 1, "started", payload), 200)
      end

      for _ <- 1..2 do
        assert %{"job" => %{"state" => "failed"}} =
                 valid_api_response(
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
               valid_api_response(report(context, job.id, token, 1, "started"), 200)

      assert %{"job" => %{"state" => "cancelled"}} =
               valid_api_response(report(context, job.id, token, 2, "cancelled"), 200)
    end

    test "rejects a token that does not hold the lease", context do
      {job, _token} = leased(context)

      assert %{"errors" => [%{"path" => "lease_token"}]} =
               valid_api_response(report(context, job.id, "not-the-token", 1, "started"), 409)
    end

    test "rejects reused or stale sequences and transitions out of order", context do
      {job, token} = leased(context)

      assert %{"errors" => [%{"path" => "type"}]} =
               valid_api_response(report(context, job.id, token, 1, "progress"), 409)

      valid_api_response(report(context, job.id, token, 2, "started"), 200)

      assert %{"errors" => [%{"path" => "sequence"}]} =
               valid_api_response(report(context, job.id, token, 2, "progress"), 409)

      assert %{"errors" => [%{"path" => "sequence"}]} =
               valid_api_response(report(context, job.id, token, 1, "progress"), 409)
    end

    test "checks results against the capability", context do
      {job, token} = leased(context)
      valid_api_response(report(context, job.id, token, 1, "started"), 200)

      assert %{"errors" => [%{"path" => "payload.result.observation_id"} | _]} =
               valid_api_response(
                 report(context, job.id, token, 2, "succeeded", %{"result" => %{}}),
                 422
               )

      assert %{"errors" => [%{"path" => "payload.reason"}]} =
               valid_api_response(report(context, job.id, token, 3, "failed"), 422)
    end

    test "rejects output beyond the job's limit", context do
      {job, token} = leased(context)
      valid_api_response(report(context, job.id, token, 1, "started"), 200)
      big = %{"chunk" => String.duplicate("x", 70_000)}

      assert %{"errors" => [%{"path" => "payload"}]} =
               valid_api_response(report(context, job.id, token, 2, "output", big), 413)
    end

    test "validates the request and the job", context do
      {job, token} = leased(context)

      for {sequence, type, payload} <- [
            {0, "started", %{}},
            {Jobs.max_report_sequence() + 1, "started", %{}},
            {1, "done", %{}},
            {1, "started", []}
          ] do
        assert %{"status" => "rejected"} =
                 valid_api_response(report(context, job.id, token, sequence, type, payload), 422)
      end

      assert context.scope |> Jobs.list_events(job) |> Enum.map(& &1.type) == ~w(created leased)

      assert %{"job" => %{"state" => "failed"}} =
               valid_api_response(
                 report(
                   context,
                   job.id,
                   token,
                   Jobs.max_report_sequence(),
                   "failed",
                   %{"reason" => "stopped"}
                 ),
                 200
               )

      assert %{"errors" => [%{"path" => "id"}]} =
               valid_api_response(report(context, Ecto.UUID.generate(), token, 1, "started"), 404)
    end

    test "never touches another organization's job", context do
      {job, token} = leased(context)
      other = job_organization_fixture()
      {:ok, {_key, other_token}} = Inventory.create_intake_api_key(other.scope, %{name: "Other"})

      assert %{"errors" => [%{"path" => "installation_id"}]} =
               valid_api_response(
                 report(%{context | token: other_token}, job.id, token, 1, "started"),
                 409
               )

      assert %{state: "leased"} = Jobs.get_job!(context.scope, job.id)
    end

    test "rejects a key revoked after authentication without recording a report", context do
      {job, token} = leased(context)
      {:ok, _key} = Inventory.revoke_intake_api_key(context.scope, context.intake_api_key.id)

      conn =
        JobController.create_event(authenticated_conn(context), %{
          "id" => job.id,
          "lease_token" => token,
          "sequence" => 1,
          "type" => "started",
          "payload" => %{}
        })

      assert %{"errors" => [%{"path" => "authorization"}]} =
               valid_api_response(conn, 401, "reportAgentJob")

      assert %{state: "leased"} = Jobs.get_job!(context.scope, job.id)
      assert context.scope |> Jobs.list_events(job) |> Enum.map(& &1.type) == ~w(created leased)
    end

    test "rejects an agent disabled after authentication without recording a report", context do
      {job, token} = leased(context)
      context.agent |> Ecto.Changeset.change(status: "disabled") |> Repo.update!()

      conn =
        JobController.create_event(authenticated_conn(context), %{
          "id" => job.id,
          "lease_token" => token,
          "sequence" => 1,
          "type" => "started",
          "payload" => %{}
        })

      assert %{"errors" => [%{"path" => "installation_id"}]} =
               valid_api_response(conn, 403, "reportAgentJob")

      assert %{state: "leased"} = Jobs.get_job!(context.scope, job.id)
      assert context.scope |> Jobs.list_events(job) |> Enum.map(& &1.type) == ~w(created leased)
    end
  end

  describe "check-in" do
    test "hints that jobs are waiting", context do
      check_in = fn -> post_json(context, ~p"/api/v1/agent/checkins", %{}) end

      assert %{"jobs_waiting" => false} = valid_api_response(check_in.(), 202)
      queue_job(context)
      assert %{"jobs_waiting" => true} = valid_api_response(check_in.(), 202)
      valid_api_response(lease(context), 200)
      assert %{"jobs_waiting" => false} = valid_api_response(check_in.(), 202)
    end
  end

  describe "POST /api/v1/agent/jobs/:id/claims" do
    setup context do
      context.organization
      |> Ecto.Changeset.change(settings: %{"jobs" => %{"allowed_capabilities" => [@restart]}})
      |> Repo.update!()

      bound = target_binding_fixture(context.organization, context.agent)

      {:ok, job} =
        Jobs.create_system_job(
          context.organization.id,
          context.agent.id,
          @restart,
          %{"service" => "nginx"},
          resource_id: bound.resource.id
        )

      Map.merge(context, %{bound: bound, job: job})
    end

    defp offered(context) do
      %{"offers" => [offer]} =
        valid_api_response(lease(context, %{"capabilities" => [@restart]}), 200)

      offer
    end

    defp signature(context, offer, private_key) do
      message =
        Renga.Jobs.SignedLeases.message(
          offer["job_id"],
          offer["lease_token"],
          offer["nonce"],
          context.installation_id,
          offer["resource_id"],
          offer["binding_version"]
        )

      :eddsa
      |> :crypto.sign(:none, message, [private_key, :ed25519])
      |> Base.url_encode64(padding: false)
    end

    defp claim(context, offer, signature) do
      post_json(context, ~p"/api/v1/agent/jobs/#{offer["job_id"]}/claims", %{
        "lease_token" => offer["lease_token"],
        "nonce" => offer["nonce"],
        "signature" => signature
      })
    end

    test "offers the job with its binding and leases it on a valid signature", context do
      offer = offered(context)
      assert offer["job_id"] == context.job.id
      assert offer["resource_id"] == context.bound.resource.id
      assert offer["binding_version"] == 1

      leased =
        context
        |> claim(offer, signature(context, offer, context.bound.private_key))
        |> valid_api_response(200)

      assert leased["id"] == context.job.id
      assert leased["lease_token"] == offer["lease_token"]
      assert leased["parameters"] == %{"service" => "nginx"}

      assert %{"status" => "accepted"} =
               context
               |> report(context.job.id, leased["lease_token"], 1, "started")
               |> valid_api_response(200)
    end

    test "rejects a signature from another key", context do
      offer = offered(context)
      {_public, stranger} = :crypto.generate_key(:eddsa, :ed25519)

      assert %{"errors" => [%{"path" => "signature"}]} =
               context
               |> claim(offer, signature(context, offer, stranger))
               |> valid_api_response(403)

      assert %{"errors" => [%{"path" => "signature"}]} =
               context |> claim(offer, "not-a-signature") |> valid_api_response(422)
    end

    test "accepts a padded signature, and a replayed claim is a conflict", context do
      offer = offered(context)
      signature = signature(context, offer, context.bound.private_key)

      {:ok, raw} = Base.url_decode64(signature, padding: false)
      padded = Base.url_encode64(raw)
      assert String.ends_with?(padded, "=")

      assert %{"id" => id} = context |> claim(offer, padded) |> valid_api_response(200)
      assert id == context.job.id

      # The offer ends when it is claimed, so the same signed claim cannot
      # lease the job a second time.
      assert %{"errors" => [%{"path" => "lease_token"}]} =
               context |> claim(offer, signature) |> valid_api_response(409)
    end

    test "a capability withdrawn after the offer fails the job at the claim", context do
      offer = offered(context)

      context.organization
      |> Repo.reload!()
      |> Ecto.Changeset.change(settings: %{"jobs" => %{"allowed_capabilities" => []}})
      |> Repo.update!()

      response =
        context
        |> claim(offer, signature(context, offer, context.bound.private_key))
        |> valid_api_response(409)

      assert %{"errors" => [%{"path" => "id"}]} = response
      refute Map.has_key?(response, "parameters")

      job = Repo.reload!(context.job)
      assert job.state == "failed"
      assert job.failure_reason == "capability_not_allowed"
      assert is_nil(job.lease_token_hash)
    end

    test "a replaced offer is a conflict", context do
      first = offered(context)
      _second = offered(context)

      assert %{"errors" => [%{"path" => "lease_token"}]} =
               context
               |> claim(first, signature(context, first, context.bound.private_key))
               |> valid_api_response(409)
    end

    test "a binding that changed fails the job with a conflict", context do
      offer = offered(context)

      context.bound.binding
      |> Ecto.Changeset.change(
        status: "revoked",
        revoked_at: Renga.Time.utc_now_ms(),
        revoked_reason: "revoked"
      )
      |> Repo.update!()

      assert %{"errors" => [%{"path" => "id"}]} =
               context
               |> claim(offer, signature(context, offer, context.bound.private_key))
               |> valid_api_response(409)

      assert Repo.reload!(context.job).failure_reason == "binding_changed"
    end
  end
end
