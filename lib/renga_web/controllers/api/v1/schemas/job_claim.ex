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
        # Prose rather than a pattern, and no additionalProperties: a request
        # schema must not reject a claim the endpoint accepts, and the endpoint
        # also takes padded signatures and ignores unknown fields.
        signature: %{
          type: :string,
          description:
            "The 64-byte Ed25519 signature in base64url, normally unpadded " <>
              "(86 characters); a padded signature is also accepted."
        }
      },
      required: [:lease_token, :nonce, :signature]
    }
  end
end
