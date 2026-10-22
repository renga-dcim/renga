defmodule RengaWeb.Operator.V1.Schemas.OwnerInvitationCreate do
  @moduledoc false

  def json_schema do
    %{
      title: "OwnerInvitationCreate",
      description: "Who to invite as an owner.",
      type: :object,
      properties: %{email: %{type: :string}},
      required: [:email],
      additionalProperties: false
    }
  end
end
