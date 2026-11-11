defmodule RengaWeb.Api.V1.JobEvidenceControllerTest do
  use RengaWeb.ConnCase, async: true

  import Renga.JobsFixtures

  alias Renga.Inventory
  alias Renga.Inventory.ReconciliationWork
  alias Renga.Jobs
  alias Renga.Jobs.Evidence
  alias Renga.Limits
  alias Renga.Repo

  setup do
    context = job_organization_fixture()
    {:ok, {key, token}} = Inventory.create_intake_api_key(context.scope, %{name: "Job fleet"})
    installation = Ecto.UUID.generate()

    {:ok, {agent, _}} =
      Inventory.record_intake_agent_check_in(context.system_scope, key, installation, %{
        capabilities: ["inventory.collect@1"]
      })

    {:ok, job} = Jobs.create_job(context.scope, agent.id, "inventory.collect@1", %{})
    Map.merge(context, %{agent: agent, job: job, token: token, installation: installation})
  end

  defp post_json(c, path, body) do
    build_conn()
    |> put_req_header("authorization", "Bearer #{c.token}")
    |> put_req_header("x-renga-installation-id", c.installation)
    |> put_req_header("content-type", "application/json")
    |> post(path, Jason.encode!(body))
  end

  defp lease(c) do
    %{"jobs" => [job]} =
      valid_api_response(
        post_json(c, ~p"/api/v1/agent/jobs/lease", %{
          capabilities: ["inventory.collect@1"],
          limit: 1
        }),
        200
      )

    job
  end

  defp body(id \\ Ecto.UUID.generate()) do
    Jason.encode!(%{
      observation_id: id,
      observed_at: "2026-07-31T12:00:00Z",
      resources: [
        %{
          kind: "server",
          identifiers: %{hostname: "protected-host"},
          attributes: %{hostname: "protected-host"}
        }
      ]
    })
  end

  defp envelope(lease, body) do
    %{
      lease_token: lease["lease_token"],
      attempt: lease["attempt"],
      sha256: :crypto.hash(:sha256, body) |> Base.encode16(case: :lower),
      body: body
    }
  end

  defp submit(c, envelope),
    do: post_json(c, ~p"/api/v1/agent/jobs/#{c.job.id}/evidence", envelope)

  defp limits(c, values),
    do: Limits.set(c.organization, values, Renga.DeploymentAudit.operator("test"))

  test "protected acceptance bypasses a full ordinary backlog and replays exactly once", c do
    limits(c, pending_work_units: 0, pending_work_bytes: 0)
    lease = lease(c)
    assert %{"items" => 1, "bytes" => 256_000, "id" => _} = lease["evidence_reservation"]
    assert Evidence.usage(c.organization.id, :items) == 1
    assert Evidence.usage(c.organization.id, :bytes) == 256_000

    body = body()
    ordinary = post_json(c, ~p"/api/v1/observations", Jason.decode!(body))
    valid_api_response(ordinary, 429)
    first = valid_api_response(submit(c, envelope(lease, body)), 202)
    second = valid_api_response(submit(c, envelope(lease, body)), 200)
    assert first["receipt"] == second["receipt"]
    assert second["duplicate"]
    assert Repo.aggregate(ReconciliationWork, :count) == 1
    assert ReconciliationWork.pending_units(c.organization.id) == 0
    assert Evidence.usage(c.organization.id, :items) == 1
    assert Evidence.usage(c.organization.id, :bytes) == 256_000

    valid_api_response(submit(c, envelope(lease, body())), 413)
    assert Repo.aggregate(Inventory.Observation, :count) == 1

    {:ok, _} =
      Jobs.report(c.system_scope, c.agent, c.job.id, lease["lease_token"], "succeeded", %{
        "result" => %{"observation_id" => first["observation"]["observation_id"]}
      })

    assert Evidence.usage(c.organization.id, :items) == 1
    assert Evidence.usage(c.organization.id, :bytes) == byte_size(body)

    assert {:ok, _, true} =
             Inventory.reconcile_observation(c.system_scope, first["observation"]["id"])

    assert Evidence.usage(c.organization.id, :items) == 0
    assert Evidence.usage(c.organization.id, :bytes) == 0
    assert ReconciliationWork.pending_bytes(c.organization.id) == 0
  end

  test "no lease or lease event is committed without the entire protected allowance", c do
    for bounds <- [[job_evidence_items: 0], [job_evidence_items: 1, job_evidence_bytes: 255_999]] do
      limits(c, bounds)
      conn = post_json(c, ~p"/api/v1/agent/jobs/lease", %{capabilities: ["inventory.collect@1"]})
      valid_api_response(conn, 429)
      assert Repo.reload!(c.job).state == "queued"
      assert Repo.reload!(c.job).attempts == 0
      assert Jobs.list_events(c.scope, c.job) |> Enum.map(& &1.type) == ["created"]
      assert Evidence.usage(c.organization.id, :items) == 0
    end

    limits(c, job_evidence_items: 1, job_evidence_bytes: 256_000)
    lease(c)
  end

  test "expiry retains accepted charges and permits only exact read-only receipt recovery", c do
    lease = lease(c)
    encoded = body()
    request = envelope(lease, encoded)
    accepted = valid_api_response(submit(c, request), 202)
    job = Repo.reload!(c.job)
    past = DateTime.add(Renga.Time.utc_now_ms(), -1)
    Repo.update!(Ecto.Changeset.change(job, lease_expires_at: past))
    valid_api_response(submit(c, request), 409)
    Jobs.sweep()
    assert Repo.reload!(job).state == "queued"
    assert Evidence.usage(c.organization.id, :items) == 1
    assert Evidence.usage(c.organization.id, :bytes) == byte_size(encoded)

    lookup =
      Map.delete(request, :body)
      |> Map.put(:observation_id, accepted["observation"]["observation_id"])

    response = post_json(c, ~p"/api/v1/agent/jobs/#{job.id}/evidence/receipt", lookup)
    assert valid_api_response(response, 200)["receipt"] == accepted["receipt"]
    assert Repo.reload!(job).state == "queued"
    assert Repo.reload!(job).lease_expires_at == nil
    assert Evidence.usage(c.organization.id, :bytes) == byte_size(encoded)
    missing = Map.put(lookup, :sha256, String.duplicate("0", 64))

    valid_api_response(
      post_json(c, ~p"/api/v1/agent/jobs/#{job.id}/evidence/receipt", missing),
      404
    )

    # RFD 9 redelivery resends the recorded outcome instead of collecting again.
    next = lease(c)
    assert next["attempt"] == 2

    assert {:ok, %{state: "succeeded"}} =
             Jobs.report(c.system_scope, c.agent, job.id, next["lease_token"], "succeeded", %{
               "result" => %{"observation_id" => accepted["observation"]["observation_id"]}
             })

    assert Evidence.usage(c.organization.id, :bytes) == byte_size(encoded)
    assert Repo.aggregate(ReconciliationWork, :count) == 1
  end

  test "success requires this job's exact accepted observation, not a claimed ID", c do
    lease = lease(c)
    id = Ecto.UUID.generate()

    assert {:error, :evidence_not_accepted} =
             Jobs.report(c.system_scope, c.agent, c.job.id, lease["lease_token"], "succeeded", %{
               "result" => %{"observation_id" => id}
             })

    valid_api_response(submit(c, envelope(lease, body(id))), 202)

    {:ok, other} = Jobs.create_job(c.scope, c.agent.id, "inventory.collect@1", %{})
    next = lease(c)

    assert {:error, :evidence_not_accepted} =
             Jobs.report(c.system_scope, c.agent, other.id, next["lease_token"], "succeeded", %{
               "result" => %{"observation_id" => id}
             })

    assert {:ok, %{state: "succeeded"}} =
             Jobs.report(c.system_scope, c.agent, c.job.id, lease["lease_token"], "succeeded", %{
               "result" => %{"observation_id" => id}
             })
  end

  test "attempt, token, installation, immutable bytes and output bounds all fence admission", c do
    lease = lease(c)
    encoded = body()
    request = envelope(lease, encoded)
    valid_api_response(submit(c, %{request | attempt: 2}), 409)
    valid_api_response(submit(c, %{request | lease_token: "other"}), 409)
    valid_api_response(submit(c, %{request | sha256: "wrong"}), 422)
    valid_api_response(submit(c, envelope(lease, String.duplicate(" ", 256_001))), 413)
    valid_api_response(submit(c, envelope(lease, "[]")), 422)
    valid_api_response(submit(c, envelope(lease, "{}")), 422)
    other = agent_fixture(c.organization)
    valid_api_response(submit(%{c | installation: other.installation_id}, request), 404)
    assert Repo.aggregate(ReconciliationWork, :count) == 0
    accepted = valid_api_response(submit(c, request), 202)
    # Whitespace changes are semantically equal JSON, but not this immutable body's digest.
    valid_api_response(submit(c, envelope(lease, encoded <> " ")), 409)
    assert Repo.aggregate(ReconciliationWork, :count) == 1
    assert accepted["duplicate"] == false
  end
end
