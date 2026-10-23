defmodule RengaWeb.Operator.V1.Schemas.OwnerInvitationCreate do
  @moduledoc false

  def json_schema do
    %{
      title: "OwnerInvitationCreate",
      description: "Who to invite as an owner.",
      type: :object,
      properties: %{
        email: %{type: :string, description: "An email address of at most 160 characters."}
      },
      required: [:email]
    }
  end
end
