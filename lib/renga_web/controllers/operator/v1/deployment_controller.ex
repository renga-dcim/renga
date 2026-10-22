defmodule RengaWeb.Operator.V1.DeploymentController do
  use RengaWeb, :controller
  use Oaskit.Controller

  alias Renga.Deployment
  alias RengaWeb.Operator.V1.Schemas

  tags ["Deployment"]

  operation :show,
    operation_id: "getDeployment",
    summary: "Describe this deployment",
    description:
      "Reports the deployment identifier and public URL, so a control plane can " <>
        "register the deployment. Any valid operator token may read it.",
    responses: [
      ok: {Schemas.Deployment, description: "This deployment."},
      unauthorized: Schemas.unauthorized_response(),
      not_found: Schemas.disabled_response()
    ]

  def show(conn, _params) do
    json(conn, %{identifier: Deployment.id(), url: Deployment.public_url()})
  end
end
