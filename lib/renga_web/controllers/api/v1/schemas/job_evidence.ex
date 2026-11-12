defmodule RengaWeb.Api.V1.Schemas.JobEvidence do
  @moduledoc false

  def json_schema do
    %{
      title: "JobEvidence",
      type: :object,
      description:
        "Attempt-bound host evidence. body is the exact encoded JSON observation (at most #{Renga.Inventory.AgentPayload.max_observation_bytes()} UTF-8 bytes), not an object. sha256 is its lowercase hexadecimal SHA-256. Only inventory.collect@1 may submit one host observation; collector/target reports are outside its output scope.",
      properties: %{
        lease_token: %{type: :string},
        attempt: %{type: :integer, minimum: 1},
        sha256: %{type: :string},
        body: %{type: :string}
      },
      required: [:lease_token, :attempt, :sha256, :body]
    }
  end
end
