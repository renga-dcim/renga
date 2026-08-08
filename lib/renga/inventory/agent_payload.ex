defmodule Renga.Inventory.AgentPayload do
  @moduledoc """
  Validation for source-authenticated agent API payloads.

  The API stores accepted observations before reconciliation, so this module
  keeps the first gate focused on tenant/source identity and payload shape.
  """

  alias Renga.Inventory.Source
  alias Renga.Types.Inet
  alias Renga.Types.MacAddress

  @max_observation_bytes 256_000
  @max_agent_metadata_bytes 16_000
  @max_agent_string_length 255
  @max_observation_id_length 255
  @max_postgres_integer 2_147_483_647
  @accepted_identifier_kinds ~w(hostname fqdn machine_id dmi_uuid serial_number mac_address provider_instance_id bmc_address)
  @matchable_identifier_kinds ~w(hostname fqdn machine_id dmi_uuid serial_number)
  @interface_kinds ~w(ethernet loopback bond bridge vlan virtual unknown)
  @identity_interface_kinds ~w(ethernet)
  @interface_statuses ~w(up down dormant not_present unknown)
  @address_kinds ~w(ipv4 ipv6)
  @prohibited_resource_keys ~w(id organization_id resource_id source_id sync_run_id)

  @doc """
  Returns the maximum accepted JSON observation payload size in bytes.
  """
  def max_observation_bytes, do: @max_observation_bytes

  @doc """
  Returns the maximum encoded JSON agent metadata size in bytes.
  """
  def max_agent_metadata_bytes, do: @max_agent_metadata_bytes

  @doc """
  Validates an agent check-in payload and returns attrs safe for the source row.
  """
  def validate_check_in(params, %Source{} = source) when is_map(params) do
    []
    |> validate_source_identity(params, source)
    |> validate_capabilities(params)
    |> validate_metadata(params)
    |> case do
      [] ->
        {:ok,
         %{}
         |> maybe_put(:capabilities, Map.get(params, "capabilities"))
         |> maybe_put(:metadata, Map.get(params, "metadata"))}

      errors ->
        {:error, Enum.reverse(errors)}
    end
  end

  def validate_check_in(_params, %Source{}),
    do: {:error, [error("body", "must be a JSON object")]}

  @doc """
  Validates a host-agent observation and returns attrs safe for raw storage.
  """
  def validate_observation(params, %Source{} = source) when is_map(params) do
    {observed_at, errors} =
      parse_required_timestamp(Map.get(params, "observed_at"), "observed_at")

    errors =
      errors
      |> validate_payload_size(params)
      |> validate_source_identity(params, source)
      |> validate_observation_id(params)
      |> validate_resources(params)

    case errors do
      [] ->
        {:ok,
         %{
           idempotency_key: blank_to_nil(Map.get(params, "observation_id")),
           observed_at: observed_at,
           payload: params
         }}

      errors ->
        {:error, Enum.reverse(errors)}
    end
  end

  def validate_observation(_params, %Source{}),
    do: {:error, [error("body", "must be a JSON object")]}

  defp validate_source_identity(errors, params, source) do
    case Map.get(params, "source") do
      nil ->
        errors

      %{} = source_params ->
        errors
        |> validate_source_kind(source_params, source)
        |> validate_source_id(source_params, source)

      _invalid ->
        [error("source", "must be an object") | errors]
    end
  end

  defp validate_source_kind(errors, params, source) do
    case Map.get(params, "kind") do
      nil -> errors
      kind when kind == source.kind -> errors
      _other -> [error("source.kind", "does not match authenticated source") | errors]
    end
  end

  defp validate_source_id(errors, params, source) do
    case Map.get(params, "source_id") do
      nil ->
        errors

      source_id when source_id in [source.id, source.name] ->
        errors

      _other ->
        [error("source.source_id", "does not match authenticated source") | errors]
    end
  end

  defp validate_capabilities(errors, params) do
    case Map.get(params, "capabilities") do
      nil ->
        errors

      capabilities when is_list(capabilities) ->
        cond do
          not Enum.all?(capabilities, &non_empty_string?/1) ->
            [error("capabilities", "must contain only non-empty strings") | errors]

          Enum.any?(capabilities, &(String.length(&1) > @max_agent_string_length)) ->
            [
              error(
                "capabilities",
                "must be at most #{@max_agent_string_length} characters"
              )
              | errors
            ]

          true ->
            errors
        end

      _invalid ->
        [error("capabilities", "must be a list of strings") | errors]
    end
  end

  defp validate_metadata(errors, params) do
    case Map.get(params, "metadata") do
      nil ->
        errors

      metadata when is_map(metadata) ->
        errors
        |> validate_agent_metadata_size(metadata)
        |> validate_agent_version(metadata)

      _invalid ->
        [error("metadata", "must be an object") | errors]
    end
  end

  defp validate_agent_metadata_size(errors, metadata) do
    case Jason.encode(metadata) do
      {:ok, encoded} when byte_size(encoded) <= @max_agent_metadata_bytes ->
        errors

      {:ok, _encoded} ->
        [error("metadata", "must encode to at most #{@max_agent_metadata_bytes} bytes") | errors]

      {:error, _reason} ->
        [error("metadata", "must be JSON encodable") | errors]
    end
  end

  defp validate_agent_version(errors, metadata) do
    case Map.get(metadata, "agent_version") do
      nil ->
        errors

      version when is_binary(version) ->
        if String.length(version) <= @max_agent_string_length do
          errors
        else
          [
            error(
              "metadata.agent_version",
              "must be at most #{@max_agent_string_length} characters"
            )
            | errors
          ]
        end

      _invalid ->
        [error("metadata.agent_version", "must be a string") | errors]
    end
  end

  defp validate_payload_size(errors, params) do
    case Jason.encode(params) do
      {:ok, encoded} when byte_size(encoded) <= @max_observation_bytes ->
        errors

      {:ok, _encoded} ->
        [error("body", "must be at most #{@max_observation_bytes} bytes") | errors]

      {:error, _reason} ->
        [error("body", "must be JSON encodable") | errors]
    end
  end

  defp validate_observation_id(errors, params) do
    case Map.get(params, "observation_id") do
      nil ->
        [error("observation_id", "is required") | errors]

      value when is_binary(value) ->
        cond do
          String.trim(value) == "" ->
            [error("observation_id", "can't be blank") | errors]

          String.length(value) > @max_observation_id_length ->
            [
              error(
                "observation_id",
                "must be at most #{@max_observation_id_length} characters"
              )
              | errors
            ]

          true ->
            errors
        end

      _invalid ->
        [error("observation_id", "must be a string") | errors]
    end
  end

  defp validate_resources(errors, params) do
    case Map.get(params, "resources") do
      [%{} = resource] ->
        validate_resource(errors, resource, "resources.0")

      nil ->
        [error("resources", "is required") | errors]

      resources when is_list(resources) ->
        [error("resources", "must contain exactly one host resource") | errors]

      _invalid ->
        [error("resources", "must be a list") | errors]
    end
  end

  defp validate_resource(errors, resource, path) do
    errors
    |> validate_no_prohibited_keys(resource, path, @prohibited_resource_keys)
    |> validate_resource_kind(resource, path)
    |> validate_identifiers(resource, path)
    |> validate_current_mac_identity(resource, path)
    |> validate_attributes(resource, path)
    |> validate_coherent_host_identity(resource, path)
    |> validate_interfaces(resource, path)
    |> validate_components(resource, path)
  end

  defp validate_resource_kind(errors, resource, path) do
    case Map.get(resource, "kind") do
      "server" -> errors
      nil -> [error("#{path}.kind", "is required") | errors]
      _other -> [error("#{path}.kind", "must be server") | errors]
    end
  end

  defp validate_identifiers(errors, resource, path) do
    case Map.get(resource, "identifiers") do
      %{} = identifiers ->
        errors
        |> validate_identifier_keys(identifiers, "#{path}.identifiers")
        |> validate_identifier_values(identifiers, "#{path}.identifiers")
        |> validate_identifier_presence(identifiers, "#{path}.identifiers")

      nil ->
        [error("#{path}.identifiers", "is required") | errors]

      _invalid ->
        [error("#{path}.identifiers", "must be an object") | errors]
    end
  end

  defp validate_identifier_keys(errors, identifiers, path) do
    identifiers
    |> Map.keys()
    |> Enum.reject(&(&1 in @accepted_identifier_kinds))
    |> Enum.reduce(errors, fn key, errors ->
      [error("#{path}.#{key}", "is not supported") | errors]
    end)
  end

  defp validate_identifier_values(errors, identifiers, path) do
    Enum.reduce(identifiers, errors, fn {kind, value}, errors ->
      cond do
        kind not in @accepted_identifier_kinds ->
          errors

        is_binary(value) ->
          errors
          |> validate_non_blank("#{path}.#{kind}", value)
          |> validate_string_value(value, "#{path}.#{kind}")
          |> validate_mac_identifier(kind, [value], "#{path}.#{kind}")

        kind in ~w(hostname fqdn) ->
          [error("#{path}.#{kind}", "must be a string") | errors]

        is_list(value) and Enum.all?(value, &non_empty_string?/1) ->
          errors
          |> validate_identifier_value_lengths(value, "#{path}.#{kind}")
          |> validate_mac_identifier(kind, value, "#{path}.#{kind}")

        true ->
          [error("#{path}.#{kind}", "must be a string or list of non-empty strings") | errors]
      end
    end)
  end

  defp validate_identifier_value_lengths(errors, values, path) do
    Enum.reduce(values, errors, fn value, errors -> validate_string_value(errors, value, path) end)
  end

  defp validate_mac_identifier(errors, "mac_address", values, path) do
    if Enum.all?(values, &match?({:ok, _mac}, MacAddress.cast(&1))) do
      errors
    else
      [error(path, "contains an invalid MAC address") | errors]
    end
  end

  defp validate_mac_identifier(errors, _kind, _values, _path), do: errors

  defp validate_identifier_presence(errors, identifiers, path) do
    has_identifier? =
      Enum.any?(identifiers, fn
        {kind, value} when kind in @accepted_identifier_kinds and is_binary(value) ->
          String.trim(value) != ""

        {kind, values} when kind in @accepted_identifier_kinds and is_list(values) ->
          Enum.any?(values, &non_empty_string?/1)

        _other ->
          false
      end)

    has_matchable_identifier? =
      Enum.any?(identifiers, fn
        {kind, value} when kind in @matchable_identifier_kinds and is_binary(value) ->
          String.trim(value) != ""

        {kind, values} when kind in @matchable_identifier_kinds and is_list(values) ->
          Enum.any?(values, &non_empty_string?/1)

        _other ->
          false
      end)

    cond do
      not has_identifier? ->
        [error(path, "must include at least one identifier") | errors]

      not has_matchable_identifier? ->
        [error(path, "must include an identifier supported by matching") | errors]

      true ->
        errors
    end
  end

  defp validate_current_mac_identity(errors, resource, path) do
    identifiers =
      case Map.get(resource, "identifiers") do
        %{} = identifiers -> identifiers
        _invalid -> %{}
      end

    case Map.get(identifiers, "mac_address") do
      nil ->
        errors

      declared_macs ->
        if normalized_mac_set(List.wrap(declared_macs)) == current_mac_set(resource) do
          errors
        else
          [
            error(
              "#{path}.identifiers.mac_address",
              "must exactly match MAC addresses on current interfaces"
            )
            | errors
          ]
        end
    end
  end

  defp current_mac_set(resource) do
    case Map.get(resource, "interfaces") do
      interfaces when is_list(interfaces) ->
        interfaces
        |> Enum.filter(
          &(is_map(&1) and &1["status"] != "not_present" and
              Map.get(&1, "kind", "ethernet") in @identity_interface_kinds)
        )
        |> Enum.flat_map(fn interface -> List.wrap(Map.get(interface, "mac_address")) end)
        |> normalized_mac_set()

      _invalid ->
        MapSet.new()
    end
  end

  defp normalized_mac_set(values) do
    values
    |> Enum.map(&Renga.Inventory.ResourceIdentifier.normalize_value("mac_address", &1))
    |> MapSet.new()
  end

  defp validate_coherent_host_identity(errors, resource, path) do
    identifiers =
      case Map.get(resource, "identifiers") do
        %{} = identifiers -> identifiers
        _invalid -> %{}
      end

    attributes =
      case Map.get(resource, "attributes") do
        %{} = attributes -> attributes
        _invalid -> %{}
      end

    Enum.reduce(~w(hostname fqdn), errors, fn field, errors ->
      identifier = Map.get(identifiers, field)
      attribute = Map.get(attributes, field)

      if is_binary(identifier) and is_binary(attribute) and
           normalize_host_identity(identifier) != normalize_host_identity(attribute) do
        [error("#{path}.attributes.#{field}", "must match the corresponding identifier") | errors]
      else
        errors
      end
    end)
  end

  defp normalize_host_identity(value), do: value |> String.trim() |> String.downcase()

  defp validate_attributes(errors, resource, path) do
    case Map.fetch(resource, "attributes") do
      :error ->
        errors

      {:ok, %{} = attributes} ->
        errors
        |> validate_no_prohibited_keys(
          attributes,
          "#{path}.attributes",
          @prohibited_resource_keys
        )
        |> validate_host_projection_fields(attributes, "#{path}.attributes")

      {:ok, _invalid} ->
        [error("#{path}.attributes", "must be an object") | errors]
    end
  end

  defp validate_interfaces(errors, resource, path) do
    case Map.get(resource, "interfaces") do
      nil ->
        errors

      interfaces when is_list(interfaces) ->
        interfaces
        |> Enum.with_index()
        |> Enum.reduce(errors, fn {interface, index}, errors ->
          validate_interface(errors, interface, "#{path}.interfaces.#{index}")
        end)

      _invalid ->
        [error("#{path}.interfaces", "must be a list") | errors]
    end
  end

  defp validate_interface(errors, %{} = interface, path) do
    errors
    |> validate_required_string(interface, "name", "#{path}.name")
    |> validate_string_length(interface, "name", "#{path}.name")
    |> validate_optional_inclusion(interface, "kind", @interface_kinds, "#{path}.kind")
    |> validate_optional_inclusion(interface, "status", @interface_statuses, "#{path}.status")
    |> validate_optional_mac(interface, "#{path}.mac_address")
    |> validate_optional_positive_integer(interface, "mtu", "#{path}.mtu")
    |> validate_optional_positive_integer(interface, "speed_mbps", "#{path}.speed_mbps")
    |> validate_optional_map(interface, "metadata", "#{path}.metadata")
    |> validate_interface_addresses(interface, path)
  end

  defp validate_interface(errors, _interface, path) do
    [error(path, "must be an object") | errors]
  end

  defp validate_optional_mac(errors, interface, path) do
    case Map.get(interface, "mac_address") do
      nil ->
        errors

      value when is_binary(value) ->
        case MacAddress.cast(value) do
          {:ok, _mac} -> errors
          :error -> [error(path, "is invalid") | errors]
        end

      _invalid ->
        [error(path, "must be a string") | errors]
    end
  end

  defp validate_interface_addresses(errors, interface, path) do
    case Map.get(interface, "addresses") do
      nil ->
        errors

      addresses when is_list(addresses) ->
        addresses
        |> Enum.with_index()
        |> Enum.reduce(errors, fn {address, index}, errors ->
          validate_address(errors, address, "#{path}.addresses.#{index}")
        end)

      _invalid ->
        [error("#{path}.addresses", "must be a list") | errors]
    end
  end

  defp validate_address(errors, address, path) when is_binary(address) do
    validate_inet_address(errors, address, path)
  end

  defp validate_address(errors, %{} = address, path) do
    errors
    |> validate_required_inet(address, "#{path}.address")
    |> validate_optional_inclusion(address, "kind", @address_kinds, "#{path}.kind")
    |> validate_optional_string(address, "scope", "#{path}.scope")
    |> validate_optional_map(address, "metadata", "#{path}.metadata")
  end

  defp validate_address(errors, _address, path) do
    [error(path, "must be a string or object") | errors]
  end

  defp validate_required_inet(errors, address, path) do
    case Map.get(address, "address") do
      value when is_binary(value) -> validate_inet_address(errors, value, path)
      nil -> [error(path, "is required") | errors]
      _invalid -> [error(path, "must be a string") | errors]
    end
  end

  defp validate_inet_address(errors, value, path) do
    case Inet.cast(value) do
      {:ok, _address} -> errors
      :error -> [error(path, "is invalid") | errors]
    end
  end

  defp validate_components(errors, resource, path) do
    case Map.get(resource, "components") do
      nil -> errors
      components when is_list(components) -> errors
      _invalid -> [error("#{path}.components", "must be a list") | errors]
    end
  end

  defp validate_no_prohibited_keys(errors, attrs, path, prohibited_keys) do
    attrs
    |> Map.keys()
    |> Enum.filter(&(&1 in prohibited_keys))
    |> Enum.reduce(errors, fn key, errors ->
      [error("#{path}.#{key}", "is not accepted") | errors]
    end)
  end

  defp validate_required_string(errors, attrs, key, path) do
    case Map.get(attrs, key) do
      value when is_binary(value) -> validate_non_blank(errors, path, value)
      nil -> [error(path, "is required") | errors]
      _invalid -> [error(path, "must be a string") | errors]
    end
  end

  defp validate_host_projection_fields(errors, attributes, path) do
    Enum.reduce(~w(hostname fqdn vendor model asset_tag), errors, fn field, errors ->
      validate_optional_string(errors, attributes, field, "#{path}.#{field}")
    end)
  end

  defp validate_optional_string(errors, attrs, key, path) do
    case Map.get(attrs, key) do
      nil -> errors
      value when is_binary(value) -> validate_string_value(errors, value, path)
      _invalid -> [error(path, "must be a string") | errors]
    end
  end

  defp validate_string_length(errors, attrs, key, path) do
    case Map.get(attrs, key) do
      value when is_binary(value) -> validate_string_value(errors, value, path)
      _missing_or_invalid -> errors
    end
  end

  defp validate_string_value(errors, value, path) do
    if String.length(value) <= @max_agent_string_length do
      errors
    else
      [error(path, "must be at most #{@max_agent_string_length} characters") | errors]
    end
  end

  defp validate_optional_positive_integer(errors, attrs, key, path) do
    case Map.get(attrs, key) do
      nil -> errors
      value when is_integer(value) and value in 1..@max_postgres_integer -> errors
      _invalid -> [error(path, "must be a positive signed 32-bit integer") | errors]
    end
  end

  defp validate_optional_map(errors, attrs, key, path) do
    case Map.get(attrs, key) do
      nil -> errors
      value when is_map(value) -> errors
      _invalid -> [error(path, "must be an object") | errors]
    end
  end

  defp validate_optional_inclusion(errors, attrs, key, accepted_values, path) do
    case Map.fetch(attrs, key) do
      :error -> errors
      {:ok, value} -> validate_inclusion_value(errors, value, accepted_values, path)
    end
  end

  defp validate_inclusion_value(errors, value, accepted_values, path) do
    if value in accepted_values do
      errors
    else
      [error(path, "is invalid") | errors]
    end
  end

  defp validate_non_blank(errors, path, value) do
    if String.trim(value) == "" do
      [error(path, "can't be blank") | errors]
    else
      errors
    end
  end

  defp parse_required_timestamp(nil, path), do: {nil, [error(path, "is required")]}

  defp parse_required_timestamp(value, path) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> {Renga.Time.floor_to_millisecond(datetime), []}
      {:error, _reason} -> {nil, [error(path, "must be an ISO 8601 timestamp")]}
    end
  end

  defp parse_required_timestamp(_value, path), do: {nil, [error(path, "must be a string")]}

  defp maybe_put(attrs, _key, nil), do: attrs
  defp maybe_put(attrs, key, value), do: Map.put(attrs, key, value)

  defp blank_to_nil(value) when is_binary(value) do
    value = String.trim(value)
    if value == "", do: nil, else: value
  end

  defp blank_to_nil(value), do: value

  defp non_empty_string?(value) when is_binary(value), do: String.trim(value) != ""
  defp non_empty_string?(_value), do: false

  defp error(path, message), do: %{path: path, message: message}
end
