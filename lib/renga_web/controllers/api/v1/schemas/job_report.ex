defmodule RengaWeb.Api.V1.Schemas.JobReport do
  @moduledoc false

  alias Renga.Jobs

  def json_schema do
    %{
      title: "JobReport",
      description:
        "One numbered report on a leased job. `started` moves the job to running; " <>
          "`progress` and `output` follow while it runs; `succeeded`, `failed`, and " <>
          "`cancelled` finish it, and `cancelled` only after cancellation was requested.",
      type: :object,
      properties: %{
        lease_token: %{type: :string, minLength: 1, description: "From the lease response."},
        sequence: %{
          type: :integer,
          minimum: 1,
          maximum: Jobs.max_report_sequence(),
          description:
            "Grows with each report in an attempt. Resending a recorded sequence is a " <>
              "safe retry that records nothing."
        },
        type: %{type: :string, enum: Jobs.report_types()},
        payload: %{
          type: :object,
          default: %{},
          description:
            "Opaque for `started`, `progress`, and `output`. A `succeeded` report carries " <>
              "`result`, an object checked against the capability; a `failed` report " <>
              "carries a non-empty string `reason`. Counts toward the job's output limit."
        }
      },
      required: [:lease_token, :sequence, :type]
    }
  end
end
