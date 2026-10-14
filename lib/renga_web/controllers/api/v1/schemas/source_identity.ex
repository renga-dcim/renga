defmodule RengaWeb.Api.V1.Schemas.SourceIdentity do
  @moduledoc false

  def json_schema do
    %{
      title: "SourceIdentity",
      description:
        "The reporting source, as the agent believes it to be. Optional: the intake key " <>
          "and installation ID already identify the source, and any value given must match it.",
      type: :object,
      properties: %{
        kind: %{type: [:string, :null], enum: ["host_agent", nil]},
        source_id: %{type: [:string, :null], description: "The source's ID or name."}
      }
    }
  end
end
