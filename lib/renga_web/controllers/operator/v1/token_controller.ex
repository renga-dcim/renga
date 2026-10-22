defmodule RengaWeb.Operator.V1.TokenController do
  use RengaWeb, :controller
  use Oaskit.Controller

  alias Renga.DeploymentAudit
  alias Renga.Operators
  alias RengaWeb.Operator.V1.Schemas

  tags ["Tokens"]

  operation :delete_self,
    operation_id: "revokeOwnToken",
    summary: "Revoke the token making this request",
    description:
      "Any authenticated token can revoke itself and needs no scope. A token cannot " <>
        "list, create, or revoke another token through the API; operators do that with " <>
        "`renga-admin operator-tokens`.",
    responses: [
      no_content: %{description: "The token is revoked."},
      unauthorized: Schemas.unauthorized_response(),
      not_found: Schemas.disabled_response()
    ]

  def delete_self(conn, _params) do
    %{operator_token: token} = conn.assigns
    [request_id] = get_resp_header(conn, "x-request-id")

    {:ok, _token} = Operators.revoke_token(token, DeploymentAudit.token(token, request_id))
    send_resp(conn, :no_content, "")
  end
end
