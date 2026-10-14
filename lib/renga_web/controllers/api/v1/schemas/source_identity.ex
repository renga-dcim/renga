defmodule RengaWeb.Api.V1.Schemas.SourceIdentity do
  @moduledoc false

  def json_schema do
    %{
      title: "SourceIdentity",
      description:
        "The reporting source. Optional: the intake key and installation ID already " <>
          "identify it.",
      type: :object,
      properties: %{
        kind: %{type: [:string, :null], enum: ["host_agent", nil]},
        source_id: %{
          type: :null,
          description:
            "Omit, or send null. These endpoints reject any value, including the " <>
              "collector's own source ID or name."
        }
      }
    }
  end
end
