defmodule RengaWeb.Api.V1.Schemas.Observation do
  @moduledoc false

  import RengaWeb.Api.V1.Schemas

  alias RengaWeb.Api.V1.Schemas.HostResource
  alias RengaWeb.Api.V1.Schemas.SourceIdentity

  def json_schema do
    contract = contract()

    %{
      title: "Observation",
      description:
        "One point-in-time report about the collector's host. The encoded body must be " <>
          "at most #{contract.max_observation_bytes} bytes. Unknown top-level fields are " <>
          "stored with the observation but not interpreted.",
      type: :object,
      properties: %{
        observation_id: %{
          type: :string,
          minLength: 1,
          description:
            "Idempotency key chosen by the agent. Resending the same payload under the " <>
              "same key is a duplicate; a different payload under it is a conflict. Must " <>
              "not be blank; at most #{contract.max_observation_id_length} characters."
        },
        observed_at:
          iso8601_timestamp(
            "When the agent collected the data. At most " <>
              "#{contract.max_future_observation_skew_seconds} seconds in the future."
          ),
        source: nullable(SourceIdentity),
        resources: %{
          type: :array,
          items: HostResource,
          minItems: 1,
          maxItems: 1,
          description: "Exactly one resource: the host itself."
        },
        section_completeness: %{
          type: :object,
          description:
            "Marks sections the agent reports in full, so anything missing from them " <>
              "can be treated as gone rather than unknown.",
          properties: Map.new(contract.completeness_sections, &{&1, %{type: :boolean}}),
          additionalProperties: false
        }
      },
      required: [:observation_id, :observed_at, :resources]
    }
  end
end
