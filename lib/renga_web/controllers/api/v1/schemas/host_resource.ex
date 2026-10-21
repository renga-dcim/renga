defmodule RengaWeb.Api.V1.Schemas.HostResource do
  @moduledoc false

  import RengaWeb.Api.V1.Schemas

  alias RengaWeb.Api.V1.Schemas.Interface

  def json_schema do
    contract = contract()

    %{
      title: "HostResource",
      description:
        "The host as the agent sees it, or for a scoped report a switch (`targets`) or VM " <>
          "(`hypervisor`) a collector reports. Fields the server assigns, such as `id`, " <>
          "are rejected. A switch or VM is matched to inventory only by " <>
          "#{Enum.join(contract.strong_identifier_kinds, ", ")}, one of which it must have.",
      type: :object,
      properties:
        contract.prohibited_resource_keys
        |> forbidden()
        |> Map.merge(%{
          "kind" => %{
            anyOf: Enum.map(["server" | collector_resource_kinds(contract)], &%{const: &1}),
            description: "`server` for a host report, `switch` or `vm` for a scoped report."
          },
          "target" =>
            nullable(
              non_blank_string(
                "For `targets` scope, required: the address of the reachable target this " <>
                  "switch was polled from. Not allowed otherwise."
              )
            ),
          "identifiers" => identifiers(contract),
          "attributes" => attributes(contract),
          "interfaces" => %{
            type: [:array, :null],
            items: Interface,
            description: "Network interfaces. Names must be unique after trimming."
          },
          "components" => %{
            type: [:array, :null],
            items: true,
            description:
              "Hardware components, stored as reported. The agent sends objects with a " <>
                "`kind` discriminator whose other fields depend on the kind."
          },
          "labels" => labels(contract)
        }),
      required: [:kind, :identifiers]
    }
  end

  defp collector_resource_kinds(contract),
    do: contract.collector_kinds |> Map.values() |> Enum.map(& &1.resource_kind) |> Enum.sort()

  defp identifiers(contract) do
    value_or_values = %{anyOf: [non_blank_string(), %{type: :array, items: non_blank_string()}]}

    properties =
      Map.new(contract.identifier_kinds, fn
        kind when kind in ~w(hostname fqdn) -> {kind, non_blank_string()}
        kind -> {kind, value_or_values}
      end)

    %{
      type: :object,
      description:
        "Identifiers used to match the host to inventory. At least one of " <>
          "#{Enum.join(contract.matchable_identifier_kinds, ", ")} is required. " <>
          "`mac_address` must list exactly the MAC addresses of the present ethernet interfaces.",
      properties: properties,
      additionalProperties: false,
      anyOf: Enum.map(contract.matchable_identifier_kinds, &%{required: [&1]})
    }
  end

  defp attributes(contract) do
    %{
      type: :object,
      description:
        "Descriptive host fields. `hostname` and `fqdn` must match the identifiers of " <>
          "the same name, ignoring case and surrounding whitespace.",
      properties:
        contract.prohibited_resource_keys
        |> forbidden()
        |> Map.merge(Map.new(contract.host_projection_fields, &{&1, nullable(string())}))
    }
  end

  defp labels(contract) do
    %{
      type: :object,
      description: "Operator-configured labels from the agent configuration.",
      maxProperties: contract.max_labels,
      propertyNames: %{
        maxLength: contract.max_label_key_length,
        pattern: json_pattern(contract.label_key_pattern)
      },
      additionalProperties: %{
        type: :string,
        description: "At most #{contract.max_label_value_length} characters."
      }
    }
  end

  # JSON Schema patterns are ECMA-262 and unanchored; Elixir anchors with \A and \z.
  defp json_pattern(regex) do
    "\\A" <> rest = Regex.source(regex)
    "^" <> String.replace_suffix(rest, "\\z", "$")
  end
end
