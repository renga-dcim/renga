defmodule RengaWeb.Operator.V1.Schemas.OrganizationCreate do
  @moduledoc false

  def json_schema do
    %{
      title: "OrganizationCreate",
      description: "A new organization, which starts with no members.",
      type: :object,
      properties: %{
        name: %{
          type: :string,
          description: "The display name, at most 255 characters."
        },
        slug: %{
          type: :string,
          description:
            "Lowercase letters, numbers, and dashes, starting with a letter or number; " <>
              "unique in the deployment and at most 255 characters."
        }
      },
      required: [:name, :slug]
    }
  end
end
