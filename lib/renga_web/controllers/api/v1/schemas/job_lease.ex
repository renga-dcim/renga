defmodule RengaWeb.Api.V1.Schemas.JobLease do
  @moduledoc false

  import RengaWeb.Api.V1.Schemas

  def json_schema do
    %{
      title: "JobLease",
      description:
        "Jobs leased to the calling installation, possibly none. Each lease lasts until " <>
          "`lease_expires_at`; every newly recorded report extends it.",
      type: :object,
      properties: %{
        jobs: %{
          type: :array,
          items: %{
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
              not_after:
                timestamp("After this time the job is no longer leased or retried.")
                |> nullable(),
              timeout_ms: nullable(%{type: :integer}),
              output_limit_bytes:
                nullable(%{
                  type: :integer,
                  minimum: 0,
                  description: "Budget for all report payloads, across every attempt."
                })
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
              :output_limit_bytes
            ],
            additionalProperties: false
          }
        }
      },
      required: [:jobs],
      additionalProperties: false
    }
  end
end
