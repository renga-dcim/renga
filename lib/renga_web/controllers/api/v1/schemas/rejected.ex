defmodule RengaWeb.Api.V1.Schemas.Rejected do
  @moduledoc false

  def json_schema do
    %{
      title: "Rejected",
      description:
        "Why a request was refused. Each error names the offending field with a " <>
          "dotted path such as `resources.0.interfaces.2.mtu`.",
      type: :object,
      properties: %{
        status: %{
          const: "rejected",
          description: "Absent when authentication failed before the payload was read."
        },
        errors: %{
          type: :array,
          minItems: 1,
          items: %{
            type: :object,
            properties: %{
              path: %{type: :string},
              message: %{type: :string},
              observation_id: %{
                type: :string,
                format: :uuid,
                description:
                  "The stored observation that already uses this observation ID " <>
                    "(idempotency conflicts only)."
              }
            },
            required: [:path, :message],
            additionalProperties: false
          }
        }
      },
      required: [:errors],
      additionalProperties: false
    }
  end
end
