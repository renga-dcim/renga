defmodule RengaWeb.Api.V1.TelemetryController do
  use RengaWeb, :controller
  use Oaskit.Controller

  alias Renga.Telemetry
  alias Renga.Telemetry.Payload
  alias RengaWeb.Api.V1.Schemas

  tags ["Intake"]
  parameter :"x-renga-installation-id", Schemas.installation_id_parameter()

  operation :create,
    operation_id: "createTelemetryBatch",
    summary: "Submit a telemetry batch",
    description:
      "Accepts timed readings, such as power draw, from the installation's host or one of " <>
        "its collector modules. Retries are safe: resending a batch under the same " <>
        "`replay_id` returns the accepted one.",
    security: Schemas.intake_security(),
    request_body: Schemas.TelemetryBatch,
    responses: [
      accepted: {Schemas.TelemetryAccepted, description: "Batch accepted."},
      ok:
        {Schemas.TelemetryAccepted,
         description: "This replay ID was already accepted with the same batch."},
      unauthorized: Schemas.unauthorized_response(),
      forbidden: {Schemas.Rejected, description: "The installation's agent is disabled."},
      conflict:
        {Schemas.Rejected,
         description:
           "The installation has not checked in yet, the `replay_id` was already used for a " <>
             "different batch, or the named collector is disabled or registered with a " <>
             "different kind."},
      unprocessable_entity: {Schemas.Rejected, description: "The batch is invalid."}
    ]

  def create(%{assigns: %{current_intake_api_key: intake_api_key}} = conn, params) do
    with {:ok, attrs} <- Payload.validate(params),
         {:ok, batch, disposition, results} <-
           Telemetry.accept_batch(
             conn.assigns.current_scope,
             intake_api_key,
             conn.assigns.current_installation_id,
             attrs
           ) do
      conn
      |> put_status(if disposition == :created, do: :accepted, else: :ok)
      |> json(
        %{
          status: "accepted",
          duplicate: disposition == :duplicate,
          batch: %{
            id: batch.id,
            replay_id: batch.replay_id,
            source_id: batch.source_id,
            received_at: DateTime.to_iso8601(batch.received_at),
            sample_count: batch.sample_count
          }
        }
        |> put_results(results)
      )
    else
      {:error, errors} when is_list(errors) -> reject(conn, :unprocessable_entity, errors)
      {:error, reason} -> rejected(conn, reason)
    end
  end

  defp put_results(body, nil), do: body
  defp put_results(body, results), do: Map.put(body, :samples, results)

  defp rejected(conn, {:replay_conflict, _batch}),
    do: reject(conn, :conflict, "replay_id", "has already been used for a different batch")

  defp rejected(conn, :agent_not_registered),
    do: reject(conn, :conflict, "installation_id", "has not checked in yet")

  defp rejected(conn, :agent_disabled),
    do: reject(conn, :forbidden, "installation_id", "belongs to a disabled agent")

  defp rejected(conn, :organization_inactive),
    do: reject(conn, :forbidden, "organization", "is suspended")

  defp rejected(conn, :collector_kind_conflict),
    do: reject(conn, :conflict, "collector.kind", "does not match the collector's kind")

  defp rejected(conn, :collector_disabled),
    do: reject(conn, :conflict, "collector.id", "is disabled")

  defp rejected(conn, :intake_credential_changed),
    do: reject(conn, :unauthorized, "authorization", "is invalid")

  defp reject(conn, status, path, message),
    do: reject(conn, status, [%{path: path, message: message}])

  defp reject(conn, status, errors) do
    conn
    |> put_status(status)
    |> json(%{status: "rejected", errors: errors})
  end
end
