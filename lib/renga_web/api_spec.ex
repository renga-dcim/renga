defmodule RengaWeb.ApiSpec do
  @moduledoc """
  The OpenAPI 3.1 document for Renga's machine API.

  It is documentation, not a validator: controllers declare operations with
  `Oaskit.Controller.operation/2`, but requests are still checked by their
  own payload modules, which keep the API's established error format. Tests
  validate responses against this document, and `priv/openapi/v1.json` holds
  the generated copy that other tools, such as the agent's contract tests,
  read. Regenerate it with `mix api.spec`.
  """

  use Oaskit

  alias Oaskit.Spec.Paths

  @impl true
  def spec do
    %{
      openapi: "3.1.1",
      info: %{
        title: "Renga API",
        version: "v1",
        description:
          "Machine API for collectors. Requests authenticate with an organization " <>
            "intake key and identify the installation with the `x-renga-installation-id` header."
      },
      paths: Paths.from_router(RengaWeb.Router, filter: &String.starts_with?(&1.path, "/api/")),
      components: %{
        securitySchemes: %{
          "intakeKey" => %{
            type: "http",
            scheme: "bearer",
            description: "An organization intake key (RFD 3)."
          }
        }
      }
    }
  end
end
