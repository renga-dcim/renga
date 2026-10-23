defmodule RengaWeb.Api.V1.Schemas.QueryBackends do
  @moduledoc false

  import RengaWeb.Api.V1.Schemas, only: [contract: 0]

  def json_schema do
    %{query_backend_statuses: statuses, max_backend_version_bytes: max_version} = contract()

    %{
      title: "QueryBackends",
      description:
        "Query backends the agent can use beyond its native operational queries (RFD 12). " <>
          "Unknown backends are ignored. The object replaces the one last reported, so " <>
          "an empty object clears a backend's status.",
      type: :object,
      properties: %{
        osquery: %{
          type: :object,
          description:
            "The local osqueryd reached over its extensions socket: available, " <>
              "not_permitted (the socket refuses the agent's account), or not_present.",
          properties: %{
            status: %{type: :string, enum: statuses},
            version: %{
              type: [:string, :null],
              description:
                "The daemon's version, when available: at most #{max_version} UTF-8 bytes."
            }
          },
          required: [:status]
        }
      }
    }
  end
end
