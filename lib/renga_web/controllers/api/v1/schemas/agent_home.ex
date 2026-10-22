defmodule RengaWeb.Api.V1.Schemas.AgentHome do
  @moduledoc false

  def json_schema do
    %{
      title: "AgentHome",
      description: "Where the agent sends every authenticated request.",
      type: :object,
      properties: %{
        home: %{
          type: :string,
          format: :uri,
          description:
            "The home deployment's origin: an `https` URL with no path, query, or " <>
              "credentials (`http` only for agents configured for insecure development). " <>
              "The agent persists it and resolves again only when its home answers `410` " <>
              "with `moved`."
        }
      },
      required: [:home],
      additionalProperties: false
    }
  end
end
