defmodule RengaWeb.Api.V1.Schemas.ObservationAccepted do
  @moduledoc false

  import RengaWeb.Api.V1.Schemas

  def json_schema do
    %{
      title: "ObservationAccepted",
      description:
        "The observation is stored. Reconciliation into inventory runs once inline; a " <>
          "failure there does not reject the observation, which stays stored for retry.",
      type: :object,
      properties: %{
        status: %{const: "accepted"},
        duplicate: %{
          type: :boolean,
          description: "True when this observation ID was already stored with the same payload."
        },
        reconciliation: %{
          type: :object,
          properties: %{
            status: %{type: :string, enum: ["succeeded", "failed"]},
            matched_resource_id:
              uuid("The inventory resource the observation matched, when known.")
              |> nullable(),
            errors: free_object("Why reconciliation failed, keyed by field or stage.")
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
      required: [:status, :duplicate, :reconciliation, :observation],
      additionalProperties: false
    }
  end
end
