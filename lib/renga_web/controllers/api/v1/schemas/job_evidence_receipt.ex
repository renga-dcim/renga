defmodule RengaWeb.Api.V1.Schemas.JobEvidenceReceipt do
  @moduledoc false

  def json_schema do
    %{
      title: "JobEvidenceReceipt",
      type: :object,
      description:
        "Read-only exact-body receipt inspection, including after expiry or completion. The original attempt token is required; this cannot accept new evidence or renew a lease.",
      properties: %{
        lease_token: %{type: :string},
        attempt: %{type: :integer, minimum: 1},
        sha256: %{type: :string},
        observation_id: %{type: :string}
      },
      required: [:lease_token, :attempt, :sha256, :observation_id]
    }
  end
end
