defmodule RengaWeb.Api.V1.JobEvidenceController do
  use RengaWeb, :controller
  use Oaskit.Controller

  alias Renga.Inventory
  alias Renga.Jobs.Evidence
  alias RengaWeb.Api.V1.JobController
  alias RengaWeb.Api.V1.ObservationController
  alias RengaWeb.Api.V1.Schemas

  tags ["Jobs"]
  parameter :"x-renga-installation-id", Schemas.installation_id_parameter()

  operation :create,
    operation_id: "submitJobEvidence",
    summary: "Durably accept protected job evidence",
    description:
      "Uses the current attempt's pre-reserved allowance, never ordinary intake capacity. Exact replay returns the original receipt; a full ordinary backlog cannot refuse covered evidence. The job lease is checked under lock and is not renewed. After expiry use inspectJobEvidenceReceipt instead.",
    security: Schemas.intake_security(),
    parameters: [id: [in: :path, required: true, schema: Schemas.uuid()]],
    request_body: Schemas.JobEvidence,
    responses: [
      accepted: {Schemas.ObservationAccepted, description: "Evidence and work durably accepted."},
      ok: {Schemas.ObservationAccepted, description: "Exact replay of this attempt's evidence."},
      unauthorized: Schemas.unauthorized_response(),
      forbidden: {Schemas.Rejected, description: "Organization or installation disabled."},
      not_found: {Schemas.Rejected, description: "No job for this installation."},
      conflict:
        {Schemas.Rejected,
         description: "Lease not held, identity conflict or installation not registered."},
      unprocessable_entity:
        {Schemas.Rejected, description: "Invalid digest, payload or capability scope."},
      request_entity_too_large:
        {Schemas.Rejected, description: "Declared evidence allowance exceeded."},
      too_many_requests:
        {Schemas.Rejected, description: "Maintenance capacity exhausted; obey Retry-After."}
    ]

  def create(conn, params), do: handle(conn, params, :create)

  operation :receipt,
    operation_id: "inspectJobEvidenceReceipt",
    summary: "Inspect exact protected evidence acceptance",
    security: Schemas.intake_security(),
    parameters: [id: [in: :path, required: true, schema: Schemas.uuid()]],
    request_body: Schemas.JobEvidenceReceipt,
    responses: [
      ok:
        {Schemas.ObservationAccepted,
         description: "Previously accepted exact evidence; no renewal or admission."},
      unauthorized: Schemas.unauthorized_response(),
      forbidden: {Schemas.Rejected, description: "Organization or installation disabled."},
      not_found:
        {Schemas.Rejected, description: "No matching evidence for this attempt and digest."},
      conflict:
        {Schemas.Rejected,
         description: "Attempt authority invalid or installation not registered."},
      unprocessable_entity: {Schemas.Rejected, description: "Invalid request fields."},
      too_many_requests:
        {Schemas.Rejected, description: "Maintenance capacity exhausted; obey Retry-After."}
    ]

  def receipt(conn, params), do: handle(conn, params, :receipt)

  defp handle(conn, params, action) do
    with :ok <- validate(params, action),
         {:ok, {observation, disposition}} <- accept(conn, params, action) do
      ObservationController.respond_to_accepted_observation(conn, observation, disposition)
    else
      error -> JobController.rejected(conn, error)
    end
  end

  defp accept(conn, params, :create) do
    Evidence.submit(
      conn.assigns.current_scope,
      conn.assigns.current_intake_api_key,
      conn.assigns.current_installation_id,
      params["id"],
      params["attempt"],
      params["lease_token"],
      params["sha256"],
      params["body"]
    )
  end

  defp accept(conn, params, :receipt) do
    scope = conn.assigns.current_scope
    key = conn.assigns.current_intake_api_key
    installation = conn.assigns.current_installation_id

    Inventory.with_intake_agent(scope, key, installation, fn agent ->
      Evidence.receipt(
        scope,
        agent,
        params["id"],
        params["attempt"],
        params["lease_token"],
        params["sha256"],
        params["observation_id"]
      )
    end)
  end

  defp validate(params, action) do
    field = if action == :create, do: "body", else: "observation_id"

    cond do
      not valid_authority_fields?(params) or not is_binary(params[field]) ->
        {:error, :invalid_evidence}

      action == :create and
          byte_size(params[field]) > Renga.Inventory.AgentPayload.max_observation_bytes() ->
        {:error, :evidence_limit_exceeded}

      true ->
        :ok
    end
  end

  defp valid_authority_fields?(params) do
    Ecto.UUID.cast(params["id"]) != :error and is_integer(params["attempt"]) and
      params["attempt"] > 0 and
      params["attempt"] <= Renga.Inventory.AgentPayload.contract().max_postgres_integer and
      is_binary(params["lease_token"]) and is_binary(params["sha256"])
  end
end
