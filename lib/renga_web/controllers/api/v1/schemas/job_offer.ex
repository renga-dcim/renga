defmodule RengaWeb.Api.V1.Schemas.JobOffer do
  @moduledoc false

  import RengaWeb.Api.V1.Schemas

  def json_schema do
    %{
      title: "JobOffer",
      description:
        "A privileged job (RFD 13) offered to the calling installation. To lease it, sign " <>
          "these lines, each ending in a newline, with the installation key and post the " <>
          "signature to the job's claim endpoint before `expires_at`: " <>
          "`renga-job-lease-v1`, `job_id`, `lease_token`, `nonce`, the installation ID, " <>
          "`resource_id`, and `binding_version`. A later lease request replaces the offer.",
      type: :object,
      properties: %{
        job_id: uuid(),
        capability: %{type: :string, description: "The `name@version` to run."},
        lease_token: %{
          type: :string,
          description: "Becomes the lease token once the claim succeeds."
        },
        nonce: %{type: :string},
        resource_id: uuid(),
        binding_version: %{
          type: :integer,
          minimum: 1,
          description: "The version of the resource's target binding the job runs under."
        },
        expires_at: timestamp()
      },
      required: [
        :job_id,
        :capability,
        :lease_token,
        :nonce,
        :resource_id,
        :binding_version,
        :expires_at
      ],
      additionalProperties: false
    }
  end
end
