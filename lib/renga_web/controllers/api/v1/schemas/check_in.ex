defmodule RengaWeb.Api.V1.Schemas.CheckIn do
  @moduledoc false

  import RengaWeb.Api.V1.Schemas

  alias RengaWeb.Api.V1.Schemas.ObservationQueue
  alias RengaWeb.Api.V1.Schemas.SourceIdentity

  def json_schema do
    %{
      title: "CheckIn",
      description: "A collector's periodic check-in. Every field is optional.",
      type: :object,
      properties: %{
        source: SourceIdentity,
        capabilities: %{
          type: :array,
          items: non_blank_string(),
          description: "Capabilities the collector can run now."
        },
        metadata: %{
          type: :object,
          description:
            "Agent metadata, stored with the source. Must encode to at most " <>
              "#{contract().max_agent_metadata_bytes} bytes of JSON.",
          properties: %{
            agent_version: string(),
            observation_queue: ObservationQueue
          }
        }
      }
    }
  end
end
