defmodule RengaWeb.Api.V1.Schemas.LeasedJob do
  @moduledoc false

  import RengaWeb.Api.V1.Schemas

  def json_schema do
    %{
      title: "LeasedJob",
      description: "A job leased to the calling installation.",
      type: :object,
      properties: %{
        id: uuid(),
        capability: %{type: :string, description: "The `name@version` to run."},
        parameters: free_object("Inputs for the capability."),
        attempt: %{type: :integer, minimum: 1},
        lease_token: %{
          type: :string,
          description: "Proves the lease on every report about this job."
        },
        lease_expires_at: timestamp(),
        not_after: timestamp("After this time the job is no longer leased or retried."),
        timeout_ms: %{type: :integer},
        evidence_reservation: %{
          type: :object,
          description:
            "Protected allowance for this lease attempt, independent of ordinary intake.",
          properties: %{
            id: uuid(),
            items: %{type: :integer, minimum: 0},
            bytes: %{type: :integer, minimum: 0}
          },
          required: [:id, :items, :bytes],
          additionalProperties: false
        },
        output_limit_bytes: %{
          type: :integer,
          minimum: 0,
          description: "Budget for all report payloads, across every attempt."
        }
      },
      required: [
        :id,
        :capability,
        :parameters,
        :attempt,
        :lease_token,
        :lease_expires_at,
        :not_after,
        :timeout_ms,
        :evidence_reservation,
        :output_limit_bytes
      ],
      additionalProperties: false
    }
  end
end
