defmodule RengaWeb.Api.V1.Schemas.JobReportAccepted do
  @moduledoc false

  import RengaWeb.Api.V1.Schemas

  alias Renga.Jobs.Job

  def json_schema do
    %{
      title: "JobReportAccepted",
      description: "The report is recorded, or was already recorded under its sequence.",
      type: :object,
      properties: %{
        status: %{const: "accepted"},
        job: %{
          type: :object,
          properties: %{
            id: uuid(),
            state: %{type: :string, enum: Job.states()},
            lease_expires_at:
              timestamp("The extended lease, or null once the job finished.") |> nullable()
          },
          required: [:id, :state, :lease_expires_at],
          additionalProperties: false
        },
        cancel_requested: %{
          type: :boolean,
          description: "True when the agent should stop and report `cancelled`."
        }
      },
      required: [:status, :job, :cancel_requested],
      additionalProperties: false
    }
  end
end
