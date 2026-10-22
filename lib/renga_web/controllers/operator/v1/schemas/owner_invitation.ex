defmodule RengaWeb.Operator.V1.Schemas.OwnerInvitation do
  @moduledoc false

  def json_schema do
    %{
      title: "OwnerInvitation",
      description:
        "An invitation to own an organization. Renga emails its link to the address; " <>
          "the secret is never returned.",
      type: :object,
      properties: %{
        id: %{type: :string, format: :uuid},
        organization_id: %{type: :string, format: :uuid},
        email: %{type: :string},
        role: %{type: :string, enum: ["owner"]},
        expires_at: %{type: :string, format: :"date-time"}
      },
      required: [:id, :organization_id, :email, :role, :expires_at],
      additionalProperties: false
    }
  end
end
