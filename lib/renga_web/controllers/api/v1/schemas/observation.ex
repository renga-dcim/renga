defmodule RengaWeb.Api.V1.Schemas.Observation do
  @moduledoc false

  import RengaWeb.Api.V1.Schemas

  alias RengaWeb.Api.V1.Schemas.CollectorTarget
  alias RengaWeb.Api.V1.Schemas.HostResource
  alias RengaWeb.Api.V1.Schemas.SourceIdentity

  def json_schema do
    contract = contract()

    %{
      title: "Observation",
      description:
        "One point-in-time report: about the collector's host (`host` scope, the " <>
          "default), or from one of its collector modules about the targets it polls " <>
          "(`targets`) or the hypervisor it reads (`hypervisor`). The encoded body must be " <>
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
        scope: %{
          type: [:string, :null],
          enum: contract.observation_scopes ++ [nil],
          description:
            "What the report is authoritative for. `host` (or omitted) for the host " <>
              "itself; `targets` from a `switch_poller`, `power_poller`, or `bmc_power` " <>
              "collector; `hypervisor` from a `vm_provider` collector."
        },
        collector: %{
          type: [:object, :null],
          description:
            "Required for `targets` and `hypervisor` scope and not allowed for `host`. " <>
              "Names the collector module reporting, which Renga resolves to its own " <>
              "source within the installation. A collector's kind never changes.",
          properties: %{
            id: %{
              type: :string,
              minLength: 1,
              description:
                "The stable collector ID from the agent configuration. At most " <>
                  "#{contract.max_collector_id_length} characters of letters, digits, " <>
                  "'.', '_', and '-', starting and ending with a letter or digit."
            },
            kind: %{type: :string, enum: contract.collector_kinds |> Map.keys() |> Enum.sort()}
          },
          required: [:id, :kind]
        },
        targets: %{
          type: [:array, :null],
          items: CollectorTarget.json_schema("address", "The target's configured address."),
          minItems: 1,
          maxItems: contract.max_scope_targets,
          description:
            "For `targets` scope, required: every target this report covers, each " <>
              "address once."
        },
        hypervisor:
          "id"
          |> CollectorTarget.json_schema("A stable ID of the hypervisor.")
          |> Map.put(:type, [:object, :null])
          |> Map.put(
            :description,
            "For `hypervisor` scope, required: the hypervisor this report covers. An " <>
              "unreachable hypervisor reports no resources."
          ),
        complete: %{
          type: [:boolean, :null],
          description:
            "For `targets` and `hypervisor` scope: whether the report contains everything " <>
              "each reachable target holds, so a resource a target no longer reports can " <>
              "be withdrawn. Partial reports never withdraw anything."
        },
        resources: %{
          type: :array,
          items: HostResource,
          maxItems: contract.max_scope_resources,
          description:
            "For `host` scope, exactly one `HostResource`: the host itself. For `targets` " <>
              "and `hypervisor` scope, any number of switches or VMs, possibly none."
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
