defmodule RengaWeb.Api.V1.Schemas.CheckInAccepted do
  @moduledoc false

  import RengaWeb.Api.V1.Schemas

  def json_schema do
    %{
      title: "CheckInAccepted",
      description: "The check-in was recorded and the collector's lease renewed.",
      type: :object,
      properties: %{
        status: %{const: "accepted"},
        source: %{
          type: :object,
          properties: %{
            id: uuid(),
            kind: %{type: :string},
            name: %{type: :string},
            last_seen_at: timestamp()
          },
          required: [:id, :kind, :name, :last_seen_at],
          additionalProperties: false
        },
        agent: %{
          type: :object,
          properties: %{
            id: uuid(),
            name: %{type: :string},
            lease_expires_at: timestamp()
          },
          required: [:id, :name, :lease_expires_at],
          additionalProperties: false
        },
        jobs_waiting: %{
          type: :boolean,
          description:
            "True when jobs are queued for this installation, so the agent should lease " <>
              "now rather than at its next lease attempt."
        },
        installation_key: %{
          type: :object,
          description:
            "The key this check-in presented and whether it is approved. Absent when " <>
              "the check-in presented no key.",
          properties: %{
            fingerprint: %{type: :string, description: "SHA256: and the unpadded base64 digest."},
            status: %{enum: ["pending", "approved"]}
          },
          required: [:fingerprint, :status],
          additionalProperties: false
        }
      },
      required: [:status, :source, :agent, :jobs_waiting],
      additionalProperties: false
    }
  end
end
