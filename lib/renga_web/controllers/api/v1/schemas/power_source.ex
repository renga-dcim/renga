defmodule RengaWeb.Api.V1.Schemas.PowerSource do
  @moduledoc false

  import RengaWeb.Api.V1.Schemas, only: [contract: 0, non_blank_string: 1]

  def json_schema do
    %{power_source_statuses: statuses} = contract()

    %{
      title: "PowerSource",
      description:
        "Whether the agent can read one power source on its host (RFD 10, \"Source status\").",
      type: :object,
      properties: %{
        source: non_blank_string("The source, such as `hwmon` or an exporter's URL."),
        status: %{enum: statuses}
      },
      required: [:source, :status]
    }
  end
end
