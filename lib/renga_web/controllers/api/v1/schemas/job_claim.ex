defmodule RengaWeb.Api.V1.Schemas.JobClaim do
  @moduledoc false

  def json_schema do
    %{
      title: "JobClaim",
      description: "A signed claim of an offered privileged job (RFD 13).",
      type: :object,
      properties: %{
        lease_token: %{type: :string, minLength: 1},
        nonce: %{type: :string, minLength: 1},
        signature: %{
          type: :string,
          pattern: "^[A-Za-z0-9_-]{86}$",
          description: "The 64-byte Ed25519 signature in unpadded base64url."
        }
      },
      required: [:lease_token, :nonce, :signature],
      additionalProperties: false
    }
  end
end
