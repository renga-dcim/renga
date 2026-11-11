defmodule RengaWeb.Api.V1.Schemas.ObservationAccepted do
  @moduledoc false

  import RengaWeb.Api.V1.Schemas

  def json_schema do
    %{
      title: "ObservationAccepted",
      description:
        "Immutable evidence and its ordered processing obligation are durably stored. " <>
          "The receipt stays fixed on replay; processing runs independently and may still be pending.",
      type: :object,
      properties: %{
        status: %{const: "accepted"},
        duplicate: %{
          type: :boolean,
          description: "True when this observation ID was already stored with the same payload."
        },
        receipt: %{
          type: :object,
          properties: %{
            id: uuid("The immutable first work receipt."),
            position: %{type: :integer, minimum: 1},
            accepted_at: timestamp()
          },
          required: [:id, :position, :accepted_at],
          additionalProperties: false
        },
        processing: %{
          type: :object,
          properties: %{
            status: %{
              type: :string,
              enum: ["pending", "succeeded", "quarantined", "quota_deferred"]
            }
          },
          required: [:status],
          additionalProperties: false
        },
        observation: %{
          type: :object,
          properties: %{
            id: uuid(),
            observation_id: %{type: :string, description: "The agent's idempotency key."},
            observed_at: timestamp(),
            source_id: uuid()
          },
          required: [:id, :observation_id, :observed_at, :source_id],
          additionalProperties: false
        }
      },
      required: [:status, :duplicate, :receipt, :processing, :observation],
      additionalProperties: false
    }
  end
end
