defmodule RengaWeb.Operator.V1.Schemas.Deployment do
  @moduledoc false

  def json_schema do
    %{
      title: "Deployment",
      description: "Facts about this deployment as a whole.",
      type: :object,
      properties: %{
        identifier: %{
          type: [:string, :null],
          description:
            "The deployment identifier new intake keys carry (RFD 23), or null when " <>
              "the deployment has none."
        },
        url: %{
          type: :string,
          format: :uri,
          description: "The public URL people and agents reach this deployment at."
        }
      },
      required: [:identifier, :url],
      additionalProperties: false
    }
  end
end
