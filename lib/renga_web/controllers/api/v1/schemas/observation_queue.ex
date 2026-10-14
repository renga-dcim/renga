defmodule RengaWeb.Api.V1.Schemas.ObservationQueue do
  @moduledoc false

  import RengaWeb.Api.V1.Schemas, only: [contract: 0]

  def json_schema do
    %{max_json_safe_integer: max, observation_queue_counts: counts} = contract()
    count = %{type: :integer, minimum: 0, maximum: max}

    %{
      title: "ObservationQueue",
      description:
        "Health of the agent's on-disk observation queue. Drop counts cover the agent's " <>
          "current run; the backlog itself survives restarts. Unknown fields are ignored.",
      type: :object,
      properties:
        counts
        |> Map.new(&{&1, count})
        |> Map.put("oldest_age_seconds", %{
          type: [:integer, :null],
          minimum: 0,
          maximum: max,
          description: "Age of the oldest queued observation, or null when nothing is queued."
        }),
      required: counts ++ ["oldest_age_seconds"]
    }
  end
end
