defmodule RengaWeb.Api.V1.Schemas.CollectorTarget do
  @moduledoc false

  import RengaWeb.Api.V1.Schemas

  def json_schema(key_field, key_description) do
    contract = contract()

    %{
      type: :object,
      properties: %{
        key_field => non_blank_string(key_description),
        "status" => %{
          type: :string,
          enum: contract.target_statuses,
          description:
            "Whether this report reached it. An unreachable target's resources stay as " <>
              "they were: unknown, never absent."
        },
        "error" => nullable(string("Why the target could not be reached."))
      },
      required: [key_field, "status"]
    }
  end
end
