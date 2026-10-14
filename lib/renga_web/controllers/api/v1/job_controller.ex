defmodule RengaWeb.Api.V1.JobController do
  @moduledoc """
  Job delivery for agents (RFD 9, "Delivery over HTTPS").

  Agents poll: they lease queued jobs addressed to their installation, then
  post numbered reports while they run them. Requests use the intake
  authentication of every other agent endpoint, which identifies an
  organization and an installation but does not prove the installation is
  who it claims (RFD 9, "Trust boundary"). Only `observe` jobs are leased
  here until per-installation credentials exist.
  """
  use RengaWeb, :controller
  use Oaskit.Controller

  alias Renga.Inventory
  alias Renga.Jobs
  alias Renga.Jobs.Job
  alias RengaWeb.Api.V1.Schemas

  @max_lease_limit 10
  @max_capabilities 64
  @max_capability_length 128

  @doc "The limits lease requests are held to, for the OpenAPI schemas."
  def contract do
    %{
      max_lease_limit: @max_lease_limit,
      max_capabilities: @max_capabilities,
      max_capability_bytes: @max_capability_length
    }
  end

  tags ["Jobs"]
  parameter :"x-renga-installation-id", Schemas.installation_id_parameter()

  operation :lease,
    operation_id: "leaseAgentJobs",
    summary: "Lease queued jobs",
    description:
      "Leases up to `limit` queued jobs for the calling installation whose capability it " <>
        "listed. Only `observe` jobs are leased until installations have their own " <>
        "credentials. The installation must have checked in first.",
    security: Schemas.intake_security(),
    request_body: Schemas.JobLeaseRequest,
    responses: [
      ok: {Schemas.JobLease, description: "Leased jobs, possibly none."},
      unauthorized: Schemas.unauthorized_response(),
      forbidden: {Schemas.Rejected, description: "The installation's agent is disabled."},
      conflict: {Schemas.Rejected, description: "The installation has not checked in yet."},
      unprocessable_entity: {Schemas.Rejected, description: "The lease request is invalid."}
    ]

  def lease(conn, params) do
    with {:ok, keys, limit} <- validate_lease(params),
         {:ok, leased} <-
           with_calling_agent(conn, fn agent ->
             Jobs.lease_jobs(conn.assigns.current_scope, agent, keys, limit,
               risk_classes: ["observe"]
             )
           end) do
      json(conn, %{jobs: Enum.map(leased, &leased_job/1)})
    else
      error -> rejected(conn, error)
    end
  end

  operation :create_event,
    operation_id: "reportAgentJob",
    summary: "Report on a leased job",
    description:
      "Records a numbered report on a job the installation holds and extends its lease. " <>
        "Resending a recorded sequence replays it without recording or extending anything. " <>
        "The response says whether cancellation was requested.",
    security: Schemas.intake_security(),
    parameters: [
      id: [in: :path, required: true, schema: Schemas.uuid(), description: "The job's ID."]
    ],
    request_body: Schemas.JobReport,
    responses: [
      ok: {Schemas.JobReportAccepted, description: "Report recorded, or replayed."},
      unauthorized: Schemas.unauthorized_response(),
      forbidden: {Schemas.Rejected, description: "The installation's agent is disabled."},
      not_found: {Schemas.Rejected, description: "No such job for this organization."},
      conflict:
        {Schemas.Rejected,
         description:
           "Stop reporting or fix the sequence: the lease is not held, the sequence was " <>
             "used for a different report or is stale, the report is not allowed in the " <>
             "job's state, or the installation has not checked in."},
      request_entity_too_large:
        {Schemas.Rejected, description: "The payload exceeds the job's output limit."},
      unprocessable_entity: {Schemas.Rejected, description: "The report is invalid."}
    ]

  def create_event(conn, %{"id" => job_id} = params) do
    with {:ok, report} <- validate_report(params),
         {:ok, job} <-
           with_calling_agent(conn, fn agent ->
             Jobs.report(
               conn.assigns.current_scope,
               agent,
               job_id,
               report.lease_token,
               report.type,
               report.payload,
               sequence: report.sequence
             )
           end) do
      json(conn, %{
        status: "accepted",
        job: %{id: job.id, state: job.state, lease_expires_at: iso8601(job.lease_expires_at)},
        cancel_requested: not is_nil(job.cancel_requested_at)
      })
    else
      error -> rejected(conn, error)
    end
  end

  defp with_calling_agent(conn, operation) do
    Inventory.with_intake_agent(
      conn.assigns.current_scope,
      conn.assigns.current_intake_api_key,
      conn.assigns.current_installation_id,
      operation
    )
  end

  defp validate_lease(params) do
    keys = Map.get(params, "capabilities")
    limit = Map.get(params, "limit", 1)

    errors =
      []
      |> check(capability_keys?(keys), "capabilities", "must be a list of name@version strings")
      |> check(
        is_integer(limit) and limit in 1..@max_lease_limit,
        "limit",
        "must be an integer from 1 to #{@max_lease_limit}"
      )

    if errors == [], do: {:ok, Enum.uniq(keys), limit}, else: {:error, errors}
  end

  defp capability_keys?(keys) when is_list(keys) and length(keys) <= @max_capabilities do
    Enum.all?(keys, &(is_binary(&1) and byte_size(&1) <= @max_capability_length))
  end

  defp capability_keys?(_keys), do: false

  defp validate_report(params) do
    token = Map.get(params, "lease_token")
    sequence = Map.get(params, "sequence")
    type = Map.get(params, "type")
    payload = Map.get(params, "payload", %{})

    errors =
      []
      |> check(is_binary(token) and token != "", "lease_token", "is required")
      |> check(
        is_integer(sequence) and sequence in 1..Jobs.max_report_sequence(),
        "sequence",
        "must be an integer from 1 to #{Jobs.max_report_sequence()}"
      )
      |> check(
        type in Jobs.report_types(),
        "type",
        "must be one of #{Enum.join(Jobs.report_types(), ", ")}"
      )
      |> check(is_map(payload), "payload", "must be an object")

    if errors == [] do
      {:ok, %{lease_token: token, sequence: sequence, type: type, payload: payload}}
    else
      {:error, errors}
    end
  end

  defp check(errors, true, _path, _message), do: errors
  defp check(errors, false, path, message), do: errors ++ [%{path: path, message: message}]

  defp leased_job({%Job{} = job, token}) do
    %{
      id: job.id,
      capability: Job.capability_key(job),
      parameters: job.parameters,
      attempt: job.attempts,
      lease_token: token,
      lease_expires_at: iso8601(job.lease_expires_at),
      not_after: iso8601(job.not_after),
      timeout_ms: job.timeout_ms,
      output_limit_bytes: job.output_limit_bytes
    }
  end

  defp iso8601(nil), do: nil
  defp iso8601(%DateTime{} = datetime), do: DateTime.to_iso8601(datetime)

  # A rejected report tells the agent what to do next: 409s mean stop
  # reporting on this job (or resend the right sequence); 4xx validation
  # errors mean the agent itself is wrong.
  defp rejected(conn, {:error, errors}) when is_list(errors),
    do: reject(conn, :unprocessable_entity, errors)

  defp rejected(conn, {:error, %Ecto.Changeset{} = changeset}),
    do: reject(conn, :unprocessable_entity, changeset_errors(changeset, "payload.result"))

  defp rejected(conn, {:error, reason}) do
    {status, path, message} = rejection(reason)
    reject(conn, status, [%{path: path, message: message}])
  end

  defp rejection(:agent_not_registered),
    do: {:conflict, "installation_id", "has not checked in yet"}

  defp rejection(:agent_disabled),
    do: {:forbidden, "installation_id", "belongs to a disabled agent"}

  defp rejection(:intake_credential_changed),
    do: {:unauthorized, "authorization", "is invalid"}

  defp rejection(:forbidden), do: {:forbidden, "authorization", "is not allowed"}
  defp rejection(:not_found), do: {:not_found, "id", "does not match a job"}
  defp rejection(:lease_not_held), do: {:conflict, "lease_token", "does not hold the job's lease"}

  defp rejection(:sequence_conflict),
    do: {:conflict, "sequence", "was already used for a different report"}

  defp rejection(:stale_sequence),
    do: {:conflict, "sequence", "is lower than a report already recorded"}

  defp rejection(:invalid_transition),
    do: {:conflict, "type", "is not allowed in the job's current state"}

  defp rejection(:output_limit_exceeded),
    do: {:request_entity_too_large, "payload", "exceeds the job's output limit"}

  defp rejection(:invalid_result),
    do: {:unprocessable_entity, "payload.result", "must be an object"}

  defp rejection(:invalid_failure), do: {:unprocessable_entity, "payload.reason", "is required"}
  defp rejection(:invalid_report), do: {:unprocessable_entity, "payload", "is invalid"}

  defp reject(conn, status, errors) do
    conn
    |> put_status(status)
    |> json(%{status: "rejected", errors: errors})
  end

  defp changeset_errors(changeset, prefix) do
    changeset
    |> Ecto.Changeset.traverse_errors(fn {message, opts} ->
      Enum.reduce(opts, message, fn {key, value}, rendered ->
        String.replace(rendered, "%{#{key}}", to_string(value))
      end)
    end)
    |> Enum.flat_map(fn {field, messages} ->
      Enum.map(messages, &%{path: "#{prefix}.#{field}", message: &1})
    end)
  end
end
