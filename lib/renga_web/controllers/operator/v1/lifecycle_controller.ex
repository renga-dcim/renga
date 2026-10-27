defmodule RengaWeb.Operator.V1.LifecycleController do
  use RengaWeb, :controller
  use Oaskit.Controller

  alias Renga.DeploymentAudit
  alias Renga.Operators
  alias Renga.Operators.OrganizationLifecycle
  alias RengaWeb.Operator.V1.Schemas

  tags ["Organizations"]

  operation :suspend,
    operation_id: "organization_suspend",
    summary: "Suspend an organization",
    description:
      "Requires organizations:write. Target-state operation, safe to retry without an " <>
        "Idempotency-Key. Scheduling retains the original 30-day deadline. Resume cancels " <>
        "pending deletion; cancellation also restores access. Neither " <>
        "reruns work. Purging cannot be cancelled.",
    parameters: [id: [in: :path, required: true, schema: %{type: :string, format: :uuid}]],
    responses: [
      ok: {Schemas.LifecycleState, description: "The committed organization lifecycle state."},
      unauthorized: Schemas.unauthorized_response(),
      forbidden: {Schemas.Error, description: "Missing organizations:write."},
      not_found: {Schemas.Error, description: "Organization not found."},
      conflict: {Schemas.Error, description: "Irreversible purge has begun."}
    ]

  operation :resume,
    operation_id: "organization_resume",
    summary: "Resume an organization and cancel pending deletion",
    parameters: [id: [in: :path, required: true, schema: %{type: :string, format: :uuid}]],
    responses: [
      ok: {Schemas.LifecycleState, description: "Committed state; cancelled work is not rerun."},
      unauthorized: Schemas.unauthorized_response(),
      forbidden: {Schemas.Error, description: "Missing organizations:write."},
      not_found: {Schemas.Error, description: "Not found."},
      conflict: {Schemas.Error, description: "Purge has begun."}
    ]

  operation :schedule_deletion,
    operation_id: "organization_schedule_deletion",
    summary: "Suspend and schedule deletion in 30 days",
    description:
      "Safe to retry without a key: the original deadline is never extended. Requires organizations:write.",
    parameters: [id: [in: :path, required: true, schema: %{type: :string, format: :uuid}]],
    responses: [
      ok: {Schemas.LifecycleState, description: "Pending deletion and its original deadline."},
      unauthorized: Schemas.unauthorized_response(),
      forbidden: {Schemas.Error, description: "Missing organizations:write."},
      not_found: {Schemas.Error, description: "Not found."},
      conflict: {Schemas.Error, description: "Purge has begun."}
    ]

  operation :cancel_deletion,
    operation_id: "organization_cancel_deletion",
    summary: "Cancel deletion and restore organization access",
    description:
      "Safe to retry without a key. Serialized with purge; requires organizations:write.",
    parameters: [id: [in: :path, required: true, schema: %{type: :string, format: :uuid}]],
    responses: [
      ok: {Schemas.LifecycleState, description: "Committed state."},
      unauthorized: Schemas.unauthorized_response(),
      forbidden: {Schemas.Error, description: "Missing organizations:write."},
      not_found: {Schemas.Error, description: "Not found."},
      conflict: {Schemas.Error, description: "Purge has begun."}
    ]

  def suspend(conn, %{"id" => id}), do: change(conn, id, "suspend")
  def resume(conn, %{"id" => id}), do: change(conn, id, "resume")
  def schedule_deletion(conn, %{"id" => id}), do: change(conn, id, "schedule_deletion")
  def cancel_deletion(conn, %{"id" => id}), do: change(conn, id, "cancel_deletion")

  defp change(conn, id, action) do
    [request_id] = get_resp_header(conn, "x-request-id")
    context = DeploymentAudit.token(conn.assigns.operator_token, request_id)

    result =
      if Operators.authorized?(conn.assigns.operator_token, "organizations:write"),
        do: OrganizationLifecycle.change(id, action, context),
        else:
          DeploymentAudit.reject(context, "organization.#{action}", :forbidden, %{target_id: id})

    case result do
      {:ok, organization} ->
        json(
          conn,
          Map.take(organization, [
            :id,
            :name,
            :slug,
            :status,
            :deletion_scheduled_at,
            :deletion_due_at
          ])
        )

      {:error, reason} ->
        status = %{forbidden: 403, not_found: 404, purging: 409}[reason]
        conn |> put_status(status) |> json(%{error: reason})
    end
  end
end
