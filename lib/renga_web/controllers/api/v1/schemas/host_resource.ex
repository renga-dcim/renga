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
          # Unconstrained here because host reports ignore it; the scoped rules
          # are in prose so this shared schema never rejects an accepted host
          # report.
          "target" => %{
            description:
              "For `targets` scope, required: the address, as a non-blank string, of the " <>
                "reachable target this switch was polled from. Not allowed for " <>
                "`hypervisor` scope, and ignored for `host` scope."
          },
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
          "labels" => labels(contract),
          "domain" => domain(contract)
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

  defp domain(contract) do
    device_list = fn items, description ->
      %{
        type: :array,
        maxItems: contract.max_domain_devices,
        items: items,
        description: description
      }
    end

    optional_strings = fn keys -> Map.new(keys, &{&1, nullable(string())}) end
    positive = nullable(%{type: :integer, minimum: 1})

    %{
      type: :object,
      description:
        "For a `vm` in a `hypervisor` report only: the hypervisor's own view of the domain. " <>
          "Running, idle, paused, and shutting-down domains occupy the hypervisor; the rest " <>
          "are only defined on it.",
      properties: %{
        "name" => non_blank_string(),
        "state" => %{type: :string, enum: contract.domain_states},
        "persistent" => %{type: [:boolean, :null]},
        "vcpus" => positive,
        "memory_mib" => positive,
        "disks" =>
          device_list.(
            %{
              type: :object,
              properties:
                Map.put(
                  optional_strings.(~w(device bus format source)),
                  "target",
                  non_blank_string()
                ),
              required: ["target"]
            },
            "Block devices by guest target name, such as `vda`."
          ),
        "interfaces" =>
          device_list.(
            %{
              type: :object,
              properties:
                ~w(source model target)
                |> optional_strings.()
                |> Map.merge(%{
                  "mac_address" => %{
                    type: :string,
                    description: "A MAC address in any common notation."
                  },
                  "type" => %{type: :string, enum: contract.domain_interface_types}
                }),
              required: ["mac_address"]
            },
            "Virtual NICs. MAC addresses are evidence only and never match the VM to a host."
          )
      },
      required: ["name", "state"]
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
