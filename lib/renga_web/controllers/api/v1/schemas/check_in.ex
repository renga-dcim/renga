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
        source: nullable(SourceIdentity),
        capabilities: %{
          type: [:array, :null],
          items: non_blank_string(),
          description: "Capabilities the collector can run now."
        },
        metadata: %{
          type: [:object, :null],
          description:
            "Agent metadata, stored with the source. Must encode to at most " <>
              "#{contract().max_agent_metadata_bytes} bytes of JSON.",
          properties: %{
            agent_version: nullable(string()),
            observation_queue: ObservationQueue,
            # The agent's separate telemetry queue (RFD 10), in the same shape.
            telemetry_queue: ObservationQueue
          }
        },
        installation_key: %{
          type: [:object, :null],
          description:
            "The installation's public key (RFD 13). Renga records the first key as " <>
              "pending until an owner or admin approves its fingerprint; a different key " <>
              "returns the installation to pending.",
          properties: %{
            algorithm: %{const: "ed25519"},
            # Prose rather than a pattern: the server also accepts the padded
            # form, and a request schema must not reject what the API accepts.
            public_key: %{
              type: :string,
              description:
                "The raw 32-byte Ed25519 public key in base64url, normally unpadded " <>
                  "(43 characters); a padded key is also accepted."
            }
          },
          required: [:algorithm, :public_key]
        }
      }
    }
  end
end
