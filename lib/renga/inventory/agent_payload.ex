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
  @accepted_identifier_kinds ~w(hostname fqdn machine_id dmi_uuid serial_number mac_address provider_instance_id bmc_address)
  @interface_kinds ~w(ethernet loopback bond bridge vlan virtual unknown)
  @interface_statuses ~w(up down dormant not_present unknown)
  @address_kinds ~w(ipv4 ipv6)
  @prohibited_resource_keys ~w(id organization_id resource_id source_id sync_run_id)

  @doc """
  Returns the maximum accepted JSON observation payload size in bytes.
  """
  def max_observation_bytes, do: @max_observation_bytes

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
      nil -> [error("observation_id", "is required") | errors]
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
        if Enum.all?(capabilities, &non_empty_string?/1) do
          errors
        else
          [error("capabilities", "must contain only non-empty strings") | errors]
        end

      _invalid ->
        [error("capabilities", "must be a list of strings") | errors]
    end
  end

  defp validate_metadata(errors, params) do
    case Map.get(params, "metadata") do
      nil -> errors
      metadata when is_map(metadata) -> errors
      _invalid -> [error("metadata", "must be an object") | errors]
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
      nil -> errors
      value when is_binary(value) -> validate_non_blank(errors, "observation_id", value)
      _invalid -> [error("observation_id", "must be a string") | errors]
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
    |> validate_attributes(resource, path)
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
          validate_non_blank(errors, "#{path}.#{kind}", value)

        is_list(value) and Enum.all?(value, &non_empty_string?/1) ->
          errors

        true ->
          [error("#{path}.#{kind}", "must be a string or list of non-empty strings") | errors]
      end
    end)
  end

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

    if has_identifier?,
      do: errors,
      else: [error(path, "must include at least one identifier") | errors]
  end

  defp validate_attributes(errors, resource, path) do
    case Map.get(resource, "attributes") do
      nil ->
        errors

      %{} = attributes ->
        validate_no_prohibited_keys(
          errors,
          attributes,
          "#{path}.attributes",
          @prohibited_resource_keys
        )

      _invalid ->
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
    |> validate_optional_inclusion(interface, "kind", @interface_kinds, "#{path}.kind")
    |> validate_optional_inclusion(interface, "status", @interface_statuses, "#{path}.status")
    |> validate_optional_mac(interface, "#{path}.mac_address")
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

  defp validate_optional_inclusion(errors, attrs, key, accepted_values, path) do
    case Map.get(attrs, key) do
      nil -> errors
      value -> validate_inclusion_value(errors, value, accepted_values, path)
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
      {:ok, datetime, _offset} -> {floor_to_millisecond(datetime), []}
      {:error, _reason} -> {nil, [error(path, "must be an ISO 8601 timestamp")]}
    end
  end

  defp parse_required_timestamp(_value, path), do: {nil, [error(path, "must be a string")]}

  defp floor_to_millisecond(%DateTime{microsecond: {microsecond, _precision}} = datetime) do
    %{datetime | microsecond: {div(microsecond, 1_000) * 1_000, 6}}
  end

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
