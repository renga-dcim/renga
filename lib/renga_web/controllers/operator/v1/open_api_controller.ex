defmodule RengaWeb.Operator.V1.OpenApiController do
  use RengaWeb, :controller
  use Oaskit.Controller

  tags ["Documentation"]

  operation :show,
    operation_id: "getOperatorOpenApi",
    summary: "This API's OpenAPI document",
    responses: [
      ok: {%{type: :object}, description: "The OpenAPI 3.1 document."},
      unauthorized: RengaWeb.Operator.V1.Schemas.unauthorized_response(),
      not_found: RengaWeb.Operator.V1.Schemas.disabled_response()
    ]

  # The committed copy, which a test keeps identical to RengaWeb.OperatorApiSpec.
  def show(conn, _params) do
    conn
    |> put_resp_content_type("application/json")
    |> send_file(200, Application.app_dir(:renga, "priv/openapi/operator-v1.json"))
  end
end
