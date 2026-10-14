defmodule RengaWeb.Api.V1.Schemas.JobLeaseRequest do
  @moduledoc false

  alias RengaWeb.Api.V1.JobController

  def json_schema do
    contract = JobController.contract()

    %{
      title: "JobLeaseRequest",
      type: :object,
      properties: %{
        capabilities: %{
          type: :array,
          maxItems: contract.max_capabilities,
          items: %{type: :string, description: "At most #{contract.max_capability_bytes} bytes."},
          description:
            "The `name@version` capabilities the agent will run now. Only jobs for these " <>
              "are leased."
        },
        limit: %{
          type: :integer,
          minimum: 1,
          maximum: contract.max_lease_limit,
          default: 1,
          description: "The most jobs to lease at once."
        }
      },
      required: [:capabilities]
    }
  end
end
