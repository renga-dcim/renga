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
        }
      },
      required: [:status, :source, :agent, :jobs_waiting],
      additionalProperties: false
    }
  end
end
