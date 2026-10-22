defmodule RengaWeb.Operator.V1.Schemas.OrganizationCreate do
  @moduledoc false

  def json_schema do
    %{
      title: "OrganizationCreate",
      description: "A new organization, which starts with no members.",
      type: :object,
      properties: %{
        name: %{type: :string},
        slug: %{
          type: :string,
          description:
            "Lowercase letters, numbers, and dashes, starting with a letter or number; " <>
              "unique in the deployment."
        }
      },
      required: [:name, :slug],
      additionalProperties: false
    }
  end
end
