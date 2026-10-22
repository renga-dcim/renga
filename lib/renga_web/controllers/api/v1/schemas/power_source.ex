defmodule RengaWeb.Api.V1.Schemas.PowerSource do
  @moduledoc false

  import RengaWeb.Api.V1.Schemas, only: [contract: 0]

  def json_schema do
    %{max_string_length: max_length, power_source_statuses: statuses} = contract()

    %{
      title: "PowerSource",
      description:
        "Whether the agent can read one power source on its host (RFD 10, \"Source status\").",
      type: :object,
      properties: %{
        source: %{
          type: :string,
          minLength: 1,
          maxLength: max_length,
          description: "The source, such as `hwmon` or an exporter's URL."
        },
        status: %{enum: statuses}
      },
      required: [:source, :status]
    }
  end
end
