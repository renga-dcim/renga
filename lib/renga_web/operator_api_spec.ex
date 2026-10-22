defmodule RengaWeb.OperatorApiSpec do
  @moduledoc """
  The OpenAPI 3.1 document for the operator API (RFD 22), served on the
  operator listener at `/operator/v1/openapi.json`. `priv/openapi/operator-v1.json`
  holds the generated copy; regenerate it with `mix api.spec`.
  """

  use Oaskit

  alias Oaskit.Spec.Paths

  @impl true
  def spec do
    %{
      openapi: "3.1.1",
      info: %{
        title: "Renga operator API",
        version: "v1",
        description:
          "API for operating a Renga deployment: organizations, policy, identity " <>
            "providers, usage, and transfers. It is served only on the operator listener, " <>
            "and requests authenticate with an operator token."
      },
      paths:
        Paths.from_router(RengaWeb.OperatorRouter,
          filter: &String.starts_with?(&1.path, "/operator/")
        ),
      components: %{
        securitySchemes: %{
          "operatorToken" => %{
            type: "http",
            scheme: "bearer",
            description: "An operator token, created with `renga-admin operator-tokens create`."
          }
        }
      },
      security: [%{"operatorToken" => []}]
    }
  end
end
