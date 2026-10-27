defmodule RengaWeb.Operator.V1.Schemas.Organization do
  @moduledoc false

  def json_schema do
    %{
      title: "Organization",
      description:
        "An organization as the operator sees it: its identity, status, and members, " <>
          "never its inventory.",
      type: :object,
      properties: %{
        id: %{type: :string, format: :uuid},
        name: %{type: :string},
        slug: %{type: :string},
        status: %{type: :string, enum: ["active", "disabled", "deletion_pending", "purging"]},
        deletion_scheduled_at: %{type: [:string, :null], format: :"date-time"},
        deletion_due_at: %{type: [:string, :null], format: :"date-time"},
        members: %{
          type: :array,
          description: "Active members, by address.",
          items: %{
            type: :object,
            properties: %{
              email: %{
                type: [:string, :null],
                description:
                  "The member's address: their global email or, for an account created " <>
                    "by the organization's own identity provider, the address that " <>
                    "provider asserts. Null when there is neither."
              },
              role: %{type: :string, enum: ["owner", "admin", "member", "viewer"]}
            },
            required: [:email, :role],
            additionalProperties: false
          }
        }
      },
      required: [:id, :name, :slug, :status, :members],
      additionalProperties: false
    }
  end
end
