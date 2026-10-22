defmodule RengaWeb.Operator.V1.Schemas.ValidationError do
  @moduledoc false

  def json_schema do
    %{
      title: "OperatorValidationError",
      description: "A request Renga refused because of what it asked for.",
      type: :object,
      properties: %{
        error: %{type: :string, enum: ["invalid"]},
        errors: %{
          type: :object,
          description: "Messages by field.",
          additionalProperties: %{type: :array, items: %{type: :string}}
        }
      },
      required: [:error, :errors],
      additionalProperties: false
    }
  end
end
