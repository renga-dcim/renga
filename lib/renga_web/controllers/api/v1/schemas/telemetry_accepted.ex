defmodule RengaWeb.Api.V1.Schemas.TelemetryAccepted do
  @moduledoc false

  import RengaWeb.Api.V1.Schemas

  def json_schema do
    %{
      title: "TelemetryAccepted",
      description: "The batch is accepted.",
      type: :object,
      properties: %{
        status: %{const: "accepted"},
        duplicate: %{
          type: :boolean,
          description: "True when the source already accepted this replay ID with this batch."
        },
        batch: %{
          type: :object,
          properties: %{
            id: uuid(),
            replay_id: %{type: :string},
            source_id: uuid(),
            received_at: timestamp(),
            sample_count: %{type: :integer, minimum: 1}
          },
          required: [:id, :replay_id, :source_id, :received_at, :sample_count],
          additionalProperties: false
        },
        samples:
          nullable(%{
            type: :object,
            description:
              "What became of the samples. Absent for a duplicate, whose samples were " <>
                "settled when it was first accepted.",
            properties: %{
              current: %{type: :integer, minimum: 0, description: "Now their series' value."},
              superseded: %{
                type: :integer,
                minimum: 0,
                description: "Not newer than their series' value, so kept out of it."
              },
              rejected: %{
                type: :integer,
                minimum: 0,
                description: "Timed implausibly far in the future."
              }
            },
            required: [:current, :superseded, :rejected],
            additionalProperties: false
          })
      },
      required: [:status, :duplicate, :batch],
      additionalProperties: false
    }
  end
end
