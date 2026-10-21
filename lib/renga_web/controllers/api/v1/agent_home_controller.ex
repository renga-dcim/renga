defmodule RengaWeb.Api.V1.AgentHomeController do
  use RengaWeb, :controller
  use Oaskit.Controller

  alias Renga.Deployment
  alias RengaWeb.Api.V1.Schemas

  tags ["Agent home"]

  operation :show,
    operation_id: "getAgentHome",
    summary: "Resolve an agent's home deployment",
    description:
      "Tells an agent which deployment to send its authenticated requests to (RFD 23). " <>
        "A deployment is its own home, so it answers with its configured public URL " <>
        "whatever identifier is asked for. A resolver serving the same request at a " <>
        "well-known address looks the identifier up instead. The request carries no " <>
        "credential.",
    parameters: [
      deployment: [
        in: :query,
        required: false,
        schema: %{type: :string},
        description:
          "The deployment identifier read from the intake key's prefix, or empty when the " <>
            "key has none."
      ]
    ],
    responses: [ok: {Schemas.AgentHome, description: "The agent's home deployment."}]

  # The answer is a constant from configuration, never derived from the
  # request, so this endpoint cannot be used to point other agents elsewhere.
  def show(conn, _params) do
    json(conn, %{home: Deployment.public_url()})
  end
end
