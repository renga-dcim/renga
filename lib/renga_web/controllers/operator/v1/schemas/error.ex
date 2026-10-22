defmodule RengaWeb.Operator.V1.Schemas.Error do
  @moduledoc false

  def json_schema do
    %{
      title: "OperatorError",
      description: "Why an operator request was refused.",
      type: :object,
      properties: %{error: %{type: :string}},
      required: [:error],
      additionalProperties: false
    }
  end
end
