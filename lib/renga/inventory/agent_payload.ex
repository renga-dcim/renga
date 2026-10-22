defmodule Renga.Inventory.AgentPayload do
  @moduledoc """
  Validation for organization-authenticated agent API payloads.

  The API stores accepted observations before reconciliation, so this module
  keeps the first gate focused on tenant/source identity and payload shape.
  """

  alias Renga.Inventory.ResourceIdentifier
  alias Renga.Inventory.Source
  alias Renga.Topology.NeighborIdentifier
  alias Renga.Types.Inet
  alias Renga.Types.MacAddress

  @max_observation_bytes 256_000
  @max_agent_metadata_bytes 16_000
  @max_agent_string_length 255
  @max_source_local_vlan_key_bytes 2_000
  @max_observation_id_length 255
  @max_future_observation_skew_seconds 300
  @max_postgres_integer 2_147_483_647
  # Integers the agent can report without JavaScript clients losing precision.
  @max_json_safe_integer 9_007_199_254_740_991
  # Mirrors `QueueReport` in agent/src/payload.rs.
  @observation_queue_counts ~w(entries bytes dropped_for_space expired rejected unreadable)
  @queue_dropped_ages ~w(dropped_earliest_age_seconds dropped_latest_age_seconds)
  @power_source_statuses ~w(available not_permitted not_present unreachable)
  @max_power_sources 32
  @query_backend_statuses ~w(available not_permitted not_present)
  @max_backend_version_bytes 64
  @accepted_identifier_kinds ~w(hostname fqdn machine_id dmi_uuid serial_number mac_address provider_instance_id bmc_address)
  @matchable_identifier_kinds ~w(hostname fqdn machine_id dmi_uuid serial_number)
  @interface_kinds ~w(ethernet loopback bond bridge vlan virtual unknown)
  @identity_interface_kinds ~w(ethernet)
  @interface_statuses ~w(up down dormant not_present unknown)
  @interface_vlan_modes ~w(access trunk tagged_all)
  @vlan_tagging_modes ~w(tagged untagged)
  @interface_relationship_kinds ~w(parent lower_device lag_member bridge_member bridged peer vrf_member backed_by)
  @address_kinds ~w(ipv4 ipv6)
  @host_projection_fields ~w(hostname fqdn vendor model asset_tag)
  @neighbor_protocols ~w(lldp cdp)
  @neighbor_chassis_id_kinds ~w(mac_address network_address local name)
  @neighbor_port_id_kinds ~w(mac_address local name)
  @completeness_sections ~w(components interface_vlans interface_neighbors interface_relationships placement)
  @prohibited_resource_keys ~w(id organization_id resource_id source_id sync_run_id)
  # RFD 11, "Observation payload": what a report is authoritative for. Each
  # collector kind reports one scope and one resource kind.
  @observation_scopes ~w(host targets hypervisor)
  @collector_kinds %{
    "bmc_power" => %{scope: "targets", resource_kind: "server"},
    "power_poller" => %{scope: "targets", resource_kind: "pdu"},
    "switch_poller" => %{scope: "targets", resource_kind: "switch"},
    "vm_provider" => %{scope: "hypervisor", resource_kind: "vm"}
  }
  @target_statuses ~w(reachable unreachable)
  # RFD 11, "Virtualization collection": what a hypervisor says about one
  # domain. Active states occupy the hypervisor; the rest are definitions.
  @domain_states ~w(running idle paused shutting_down shutoff crashed pmsuspended unknown)
  @domain_interface_types ~w(bridge network direct user other)
  @max_domain_devices 256
  @strong_identifier_kinds ~w(serial_number dmi_uuid machine_id)
  @max_scope_resources 1_000
  @max_scope_targets 1_000
  @max_collector_id_length 64
  @collector_id_pattern ~r/\A[A-Za-z0-9]([A-Za-z0-9._-]*[A-Za-z0-9])?\z/
  # Mirrors the agent's own label validation (agent/src/config.rs).
  @max_labels 32
  @max_label_key_length 63
  @max_label_value_length 255
  @label_key_pattern ~r|\A[A-Za-z0-9]([A-Za-z0-9._/-]*[A-Za-z0-9])?\z|

  @doc """
  Returns the maximum accepted JSON observation payload size in bytes.
  """
  def max_observation_bytes, do: @max_observation_bytes

  @doc """
  Returns the maximum encoded JSON agent metadata size in bytes.
  """
  def max_agent_metadata_bytes, do: @max_agent_metadata_bytes

  @doc """
  Returns the vocabularies and limits this module enforces.

  The OpenAPI schemas in `RengaWeb.Api.V1.Schemas` read them from here, so the
  published contract cannot drift from what the API accepts.
  """
  def contract do
    %{
      max_observation_bytes: @max_observation_bytes,
      max_agent_metadata_bytes: @max_agent_metadata_bytes,
      max_string_length: @max_agent_string_length,
      max_observation_id_length: @max_observation_id_length,
      max_future_observation_skew_seconds: @max_future_observation_skew_seconds,
      max_postgres_integer: @max_postgres_integer,
      max_json_safe_integer: @max_json_safe_integer,
      max_source_local_vlan_key_bytes: @max_source_local_vlan_key_bytes,
      observation_queue_counts: @observation_queue_counts,
      queue_dropped_ages: @queue_dropped_ages,
      power_source_statuses: @power_source_statuses,
      max_power_sources: @max_power_sources,
      query_backend_statuses: @query_backend_statuses,
      max_backend_version_bytes: @max_backend_version_bytes,
      identifier_kinds: @accepted_identifier_kinds,
      matchable_identifier_kinds: @matchable_identifier_kinds,
      prohibited_resource_keys: @prohibited_resource_keys,
      host_projection_fields: @host_projection_fields,
      interface_kinds: @interface_kinds,
      interface_statuses: @interface_statuses,
      interface_vlan_modes: @interface_vlan_modes,
      vlan_tagging_modes: @vlan_tagging_modes,
      interface_relationship_kinds: @interface_relationship_kinds,
      address_kinds: @address_kinds,
      neighbor_protocols: @neighbor_protocols,
      neighbor_chassis_id_kinds: @neighbor_chassis_id_kinds,
      neighbor_port_id_kinds: @neighbor_port_id_kinds,
      completeness_sections: @completeness_sections,
      observation_scopes: @observation_scopes,
      collector_kinds: @collector_kinds,
      domain_states: @domain_states,
      domain_interface_types: @domain_interface_types,
      max_domain_devices: @max_domain_devices,
      target_statuses: @target_statuses,
      strong_identifier_kinds: @strong_identifier_kinds,
      max_scope_resources: @max_scope_resources,
      max_scope_targets: @max_scope_targets,
      max_collector_id_length: @max_collector_id_length,
      collector_id_pattern: @collector_id_pattern,
      max_labels: @max_labels,
      max_label_key_length: @max_label_key_length,
      max_label_value_length: @max_label_value_length,
      label_key_pattern: @label_key_pattern
    }
  end

  @doc """
  Validates an agent check-in payload and returns attrs safe for the source row.
  """
  def validate_check_in(params, %Source{} = source) when is_map(params) do
    []
    |> validate_source_identity(params, source)
    |> validate_capabilities(params)
    |> validate_metadata(params)
    |> validate_installation_key(params)
    |> case do
      [] ->
        {:ok,
         %{}
         |> maybe_put(:capabilities, Map.get(params, "capabilities"))
         |> maybe_put(:metadata, Map.get(params, "metadata"))
         |> maybe_put(:installation_key, installation_key(params))}

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
      |> validate_observation_clock(observed_at)
      |> validate_payload_size(params)
      |> validate_source_identity(params, source)
      |> validate_observation_id(params)
      |> validate_section_completeness(params)
      |> validate_scope(params)

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

  # RFD 13: an Ed25519 public key, raw 32 bytes in unpadded base64url.
  defp validate_installation_key(errors, params) do
    case Map.get(params, "installation_key") do
      nil ->
        errors

      %{"algorithm" => "ed25519", "public_key" => public_key} when is_binary(public_key) ->
        case decode_public_key(public_key) do
          {:ok, _key} ->
            errors

          :error ->
            [error("installation_key.public_key", "must be a 32-byte key in base64url") | errors]
        end

      %{"algorithm" => algorithm} when algorithm != "ed25519" ->
        [error("installation_key.algorithm", "must be ed25519") | errors]

      %{} ->
        [error("installation_key", "must have an algorithm and a public_key") | errors]

      _invalid ->
        [error("installation_key", "must be an object") | errors]
    end
  end

  defp installation_key(%{"installation_key" => %{"public_key" => public_key}}) do
    {:ok, key} = decode_public_key(public_key)
    %{algorithm: "ed25519", public_key: key}
  end

  defp installation_key(_params), do: nil

  defp decode_public_key(encoded) do
    case Base.url_decode64(encoded, padding: false) do
      {:ok, <<_::binary-size(32)>> = key} -> {:ok, key}
      _invalid -> :error
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
        |> validate_queue(metadata, "observation_queue")
        |> validate_queue(metadata, "telemetry_queue")
        |> validate_power_sources(metadata)
        |> validate_query_backends(metadata)

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

  # The agent's on-disk queue health, shown per collector: observations, and
  # telemetry in its own queue (RFD 10). Fields this server does not know are
  # ignored so a newer agent can add some without losing its lease.
  defp validate_queue(errors, metadata, name) do
    case Map.fetch(metadata, name) do
      :error ->
        errors

      {:ok, queue} ->
        queue_errors(queue, name) ++ errors
    end
  end

  # Whether each power source can be read on the host (RFD 10, "Source status").
  defp validate_power_sources(errors, metadata) do
    case Map.fetch(metadata, "power_sources") do
      :error -> errors
      {:ok, sources} -> power_sources_errors(sources) ++ errors
    end
  end

  @doc "Validates a power source status report, incoming or stored."
  def power_sources_errors(sources) when is_list(sources) do
    if length(sources) > @max_power_sources do
      [error("metadata.power_sources", "must have at most #{@max_power_sources} entries")]
    else
      sources
      |> Enum.with_index()
      |> Enum.flat_map(fn {source, index} ->
        power_source_errors(source, "metadata.power_sources.#{index}")
      end)
    end
  end

  def power_sources_errors(_invalid), do: [error("metadata.power_sources", "must be an array")]

  defp power_source_errors(%{"source" => name, "status" => status}, path) do
    name_errors =
      if is_binary(name) and String.trim(name) != "" and
           String.length(name) <= @max_agent_string_length,
         do: [],
         else: [
           error(
             "#{path}.source",
             "must be a non-blank string of at most #{@max_agent_string_length} characters"
           )
         ]

    status_errors =
      if status in @power_source_statuses,
        do: [],
        else: [
          error("#{path}.status", "must be one of #{Enum.join(@power_source_statuses, ", ")}")
        ]

    name_errors ++ status_errors
  end

  defp power_source_errors(_source, path),
    do: [error(path, "must be an object with a source and a status")]

  @doc "Validates both incoming queue reports and metadata stored before this contract existed."
  def observation_queue_errors(queue), do: queue_errors(queue, "observation_queue")

  @doc "Validates a telemetry queue report, which has the observation queue's shape."
  def telemetry_queue_errors(queue), do: queue_errors(queue, "telemetry_queue")

  defp queue_errors(queue, name) when is_map(queue) do
    []
    |> validate_queue_counts(queue, name)
    |> validate_queue_age(queue, name)
    |> validate_dropped_ages(queue, name)
  end

  defp queue_errors(_invalid, name), do: [error("metadata.#{name}", "must be an object")]

  defp validate_queue_counts(errors, queue, name) do
    Enum.reduce(@observation_queue_counts, errors, fn key, errors ->
      if queue_count?(Map.get(queue, key)),
        do: errors,
        else: [error("metadata.#{name}.#{key}", "must be a non-negative integer") | errors]
    end)
  end

  defp validate_queue_age(errors, queue, name) do
    path = "metadata.#{name}.oldest_age_seconds"

    case Map.fetch(queue, "oldest_age_seconds") do
      {:ok, nil} ->
        errors

      {:ok, age} ->
        if queue_count?(age),
          do: errors,
          else: [error(path, "must be a non-negative integer or null") | errors]

      :error ->
        [error(path, "is required") | errors]
    end
  end

  # How long ago the earliest and latest entries dropped for space or age were
  # queued. Both are absent until the agent drops one.
  defp validate_dropped_ages(errors, queue, name) do
    Enum.reduce(@queue_dropped_ages, errors, fn key, errors ->
      if dropped_age?(queue, key),
        do: errors,
        else: [error("metadata.#{name}.#{key}", "must be a non-negative integer") | errors]
    end)
  end

  defp dropped_age?(queue, key) do
    case Map.fetch(queue, key) do
      :error -> true
      {:ok, age} -> queue_count?(age)
    end
  end

  # The query backends the agent can use beyond its native queries (RFD 12).
  # Backends this server does not know are ignored, as queue fields are.
  defp validate_query_backends(errors, metadata) do
    case Map.fetch(metadata, "query_backends") do
      :error -> errors
      {:ok, backends} -> query_backends_errors(backends) ++ errors
    end
  end

  @doc "Validates reported query backends, and metadata stored before this contract existed."
  def query_backends_errors(backends) when is_map(backends) do
    case Map.fetch(backends, "osquery") do
      :error -> []
      {:ok, osquery} -> backend_errors("metadata.query_backends.osquery", osquery)
    end
  end

  def query_backends_errors(_invalid),
    do: [error("metadata.query_backends", "must be an object")]

  defp backend_errors(path, %{"status" => status} = backend)
       when status in @query_backend_statuses do
    case Map.get(backend, "version") do
      nil ->
        []

      version when is_binary(version) and byte_size(version) <= @max_backend_version_bytes ->
        []

      _invalid ->
        [
          error(
            "#{path}.version",
            "must be a string of at most #{@max_backend_version_bytes} bytes"
          )
        ]
    end
  end

  defp backend_errors(path, backend) when is_map(backend),
    do: [error("#{path}.status", "must be one of #{Enum.join(@query_backend_statuses, ", ")}")]

  defp backend_errors(path, _invalid), do: [error(path, "must be an object")]

  defp queue_count?(value),
    do: is_integer(value) and value >= 0 and value <= @max_json_safe_integer

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

  @doc """
  The scope an observation reports: `"host"` for the agent's own host, or a
  collector stream's `"targets"` or `"hypervisor"` (RFD 11).
  """
  def observation_scope(%{"scope" => scope}) when scope in @observation_scopes, do: scope
  def observation_scope(_payload), do: "host"

  @doc "Whether the payload is a collector stream's multi-resource report."
  def scoped_report?(payload), do: observation_scope(payload) != "host"

  @doc """
  The collector stream a validated report names, as `{collector_id, kind}`,
  or `nil` for a host report.
  """
  def collector(%{"collector" => %{"id" => id, "kind" => kind}}) when is_binary(id),
    do: {String.trim(id), kind}

  def collector(_payload), do: nil

  @doc """
  The targets a validated report covers, as `%{key, status, error}` maps: a
  switch poller's target addresses or the one hypervisor.
  """
  def report_targets(%{"scope" => "targets", "targets" => targets}),
    do: Enum.map(targets, &report_target(&1, "address"))

  def report_targets(%{"scope" => "hypervisor", "hypervisor" => hypervisor}),
    do: [report_target(hypervisor, "id")]

  def report_targets(_payload), do: []

  defp report_target(target, key_field) do
    %{
      key: String.trim(Map.fetch!(target, key_field)),
      status: Map.fetch!(target, "status"),
      error: blank_to_nil(Map.get(target, "error"))
    }
  end

  @doc "Whether the report says it is the whole of each reachable target it covers."
  def complete_report?(payload), do: Map.get(payload, "complete") == true

  @doc """
  Splits a validated report into one single-resource payload per resource,
  each naming the target it belongs to under `"target"`. The derived payloads
  keep the report's scope, collector ID and kind, time, and section
  completeness, so they reconcile like host observations.
  """
  def derived_resource_payloads(%{"resources" => resources} = payload) do
    # Only the normalized collector identity is copied: anything else in the
    # collector object stays in the raw report rather than being multiplied
    # into every derived observation.
    {collector_id, kind} = collector(payload)

    shared =
      payload
      |> Map.take(~w(observation_id observed_at scope section_completeness))
      |> Map.put("collector", %{"id" => collector_id, "kind" => kind})

    resources
    |> Enum.with_index()
    |> Enum.map(fn {resource, index} ->
      {index,
       shared
       |> Map.put("target", resource_target(payload, resource))
       |> Map.put("resources", [Map.delete(resource, "target")])}
    end)
  end

  defp resource_target(%{"scope" => "hypervisor", "hypervisor" => %{"id" => id}}, _resource),
    do: String.trim(id)

  defp resource_target(_payload, %{"target" => target}), do: String.trim(target)

  defp validate_scope(errors, params) do
    case Map.get(params, "scope") do
      scope when scope in [nil, "host"] ->
        errors
        |> validate_absent(params, "collector", "is only allowed for targets or hypervisor scope")
        |> validate_absent(params, "targets", "is only allowed for targets scope")
        |> validate_absent(params, "hypervisor", "is only allowed for hypervisor scope")
        |> validate_absent(params, "complete", "is only allowed for targets or hypervisor scope")
        |> validate_resources(params)

      scope when scope in ["targets", "hypervisor"] ->
        validate_scoped_report(errors, params, scope)

      _invalid ->
        [error("scope", "must be one of #{Enum.join(@observation_scopes, ", ")}") | errors]
    end
  end

  defp validate_absent(errors, params, key, message) do
    if Map.get(params, key) == nil, do: errors, else: [error(key, message) | errors]
  end

  defp validate_scoped_report(errors, params, scope) do
    {errors, resource_kind} = validate_collector(errors, Map.get(params, "collector"), scope)

    {errors, targets} =
      case scope do
        "targets" ->
          errors
          |> validate_absent(params, "hypervisor", "is only allowed for hypervisor scope")
          |> validate_targets(Map.get(params, "targets"))

        "hypervisor" ->
          errors
          |> validate_absent(params, "targets", "is only allowed for targets scope")
          |> validate_hypervisor(Map.get(params, "hypervisor"))
      end

    errors =
      case Map.get(params, "complete") do
        value when is_boolean(value) or is_nil(value) -> errors
        _invalid -> [error("complete", "must be a boolean") | errors]
      end

    validate_scoped_resources(errors, Map.get(params, "resources"), scope, resource_kind, targets)
  end

  defp validate_collector(errors, %{} = collector, scope) do
    errors = validate_collector_id(errors, Map.get(collector, "id"))

    case Map.fetch(@collector_kinds, Map.get(collector, "kind")) do
      {:ok, %{scope: ^scope, resource_kind: resource_kind}} ->
        {errors, resource_kind}

      {:ok, _other_scope} ->
        {[error("collector.kind", "does not report #{scope} scope") | errors], nil}

      :error ->
        kinds = @collector_kinds |> Map.keys() |> Enum.sort() |> Enum.join(", ")
        {[error("collector.kind", "must be one of #{kinds}") | errors], nil}
    end
  end

  defp validate_collector(errors, nil, _scope),
    do: {[error("collector", "is required for a scoped report") | errors], nil}

  defp validate_collector(errors, _invalid, _scope),
    do: {[error("collector", "must be an object") | errors], nil}

  defp validate_collector_id(errors, id) when is_binary(id) do
    id = String.trim(id)

    cond do
      String.length(id) > @max_collector_id_length ->
        [error("collector.id", "must be at most #{@max_collector_id_length} characters") | errors]

      not Regex.match?(@collector_id_pattern, id) ->
        [
          error(
            "collector.id",
            "must start and end with a letter or digit and contain only letters, " <>
              "digits, '.', '_', and '-'"
          )
          | errors
        ]

      true ->
        errors
    end
  end

  defp validate_collector_id(errors, nil), do: [error("collector.id", "is required") | errors]

  defp validate_collector_id(errors, _invalid),
    do: [error("collector.id", "must be a string") | errors]

  defp validate_targets(errors, targets) when is_list(targets) do
    cond do
      targets == [] ->
        {[error("targets", "must not be empty") | errors], %{}}

      length(targets) > @max_scope_targets ->
        {[error("targets", "must have at most #{@max_scope_targets} entries") | errors], %{}}

      true ->
        targets
        |> Enum.with_index()
        |> Enum.reduce({errors, %{}}, &validate_target_entry/2)
    end
  end

  defp validate_targets(errors, nil), do: {[error("targets", "is required") | errors], %{}}

  defp validate_targets(errors, _invalid),
    do: {[error("targets", "must be a list") | errors], %{}}

  defp validate_target_entry({target, index}, {errors, statuses}) do
    path = "targets.#{index}"
    errors = validate_target(errors, target, "address", path)

    with %{"address" => address, "status" => status} when is_binary(address) <- target,
         address = String.trim(address),
         false <- Map.has_key?(statuses, address) do
      {errors, Map.put(statuses, address, status)}
    else
      true -> {[error("#{path}.address", "must be unique") | errors], statuses}
      _invalid -> {errors, statuses}
    end
  end

  defp validate_hypervisor(errors, %{} = hypervisor) do
    errors = validate_target(errors, hypervisor, "id", "hypervisor")

    case hypervisor do
      %{"id" => id, "status" => status} when is_binary(id) ->
        {errors, %{String.trim(id) => status}}

      _invalid ->
        {errors, %{}}
    end
  end

  defp validate_hypervisor(errors, nil), do: {[error("hypervisor", "is required") | errors], %{}}

  defp validate_hypervisor(errors, _invalid),
    do: {[error("hypervisor", "must be an object") | errors], %{}}

  defp validate_target(errors, %{} = target, key_field, path) do
    errors
    |> validate_target_string(target, key_field, path, required: true)
    |> validate_target_string(target, "error", path, required: false)
    |> then(fn errors ->
      if Map.get(target, "status") in @target_statuses,
        do: errors,
        else: [
          error("#{path}.status", "must be one of #{Enum.join(@target_statuses, ", ")}")
          | errors
        ]
    end)
  end

  defp validate_target(errors, _invalid, _key_field, path),
    do: [error(path, "must be an object") | errors]

  defp validate_target_string(errors, target, field, path, required: required?) do
    case Map.get(target, field) do
      nil when required? ->
        [error("#{path}.#{field}", "is required") | errors]

      nil ->
        errors

      value when is_binary(value) ->
        cond do
          required? and String.trim(value) == "" ->
            [error("#{path}.#{field}", "can't be blank") | errors]

          String.length(value) > @max_agent_string_length ->
            [
              error("#{path}.#{field}", "must be at most #{@max_agent_string_length} characters")
              | errors
            ]

          true ->
            errors
        end

      _invalid ->
        [error("#{path}.#{field}", "must be a string") | errors]
    end
  end

  defp validate_scoped_resources(errors, resources, scope, resource_kind, targets)
       when is_list(resources) do
    if length(resources) > @max_scope_resources do
      [error("resources", "must have at most #{@max_scope_resources} entries") | errors]
    else
      resources
      |> Enum.with_index()
      |> Enum.reduce(errors, fn
        {%{} = resource, index}, errors ->
          path = "resources.#{index}"

          errors
          |> validate_resource(resource, path, resource_kind)
          |> validate_strong_identity(resource, path)
          |> validate_resource_target(resource, path, scope, targets)

        {_invalid, index}, errors ->
          [error("resources.#{index}", "must be an object") | errors]
      end)
    end
  end

  defp validate_scoped_resources(errors, nil, _scope, _resource_kind, _targets),
    do: [error("resources", "is required") | errors]

  defp validate_scoped_resources(errors, _invalid, _scope, _resource_kind, _targets),
    do: [error("resources", "must be a list") | errors]

  # Collector resources are matched only by stable identifiers: a switch's or
  # VM's name is no evidence that it is the host of the same name.
  defp validate_strong_identity(errors, resource, path) do
    identifiers =
      case Map.get(resource, "identifiers") do
        %{} = identifiers -> identifiers
        _invalid -> %{}
      end

    strong? =
      Enum.any?(@strong_identifier_kinds, fn kind ->
        identifiers |> Map.get(kind) |> List.wrap() |> Enum.any?(&non_empty_string?/1)
      end)

    if strong?,
      do: errors,
      else: [
        error(
          "#{path}.identifiers",
          "must include one of #{Enum.join(@strong_identifier_kinds, ", ")}"
        )
        | errors
      ]
  end

  defp validate_resource_target(errors, resource, path, "targets", targets) do
    case Map.get(resource, "target") do
      target when is_binary(target) ->
        case Map.fetch(targets, String.trim(target)) do
          {:ok, "reachable"} ->
            errors

          {:ok, _unreachable} ->
            [error("#{path}.target", "must be a reachable target") | errors]

          :error ->
            [error("#{path}.target", "must name one of the report's targets") | errors]
        end

      nil ->
        [error("#{path}.target", "is required") | errors]

      _invalid ->
        [error("#{path}.target", "must be a string") | errors]
    end
  end

  defp validate_resource_target(errors, resource, path, "hypervisor", targets) do
    errors =
      if Map.get(resource, "target") != nil,
        do: [error("#{path}.target", "is only allowed for targets scope") | errors],
        else: errors

    if Enum.any?(targets, fn {_id, status} -> status == "unreachable" end),
      do: [error(path, "must not be reported for an unreachable hypervisor") | errors],
      else: errors
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

  defp validate_resource(errors, resource, path, kind \\ "server") do
    errors
    |> validate_no_prohibited_keys(resource, path, @prohibited_resource_keys)
    |> validate_resource_kind(resource, path, kind)
    |> validate_identifiers(resource, path)
    |> validate_current_mac_identity(resource, path)
    |> validate_attributes(resource, path)
    |> validate_coherent_host_identity(resource, path)
    |> validate_interfaces(resource, path)
    |> validate_components(resource, path)
    |> validate_labels(resource, path)
    |> validate_domain(resource, path, kind)
  end

  defp validate_domain(errors, resource, path, kind) do
    case {Map.fetch(resource, "domain"), kind} do
      {:error, _kind} ->
        errors

      {{:ok, %{} = domain}, "vm"} ->
        path = "#{path}.domain"

        errors
        |> validate_required_string(domain, "name", "#{path}.name")
        |> validate_string_length(domain, "name", "#{path}.name")
        |> validate_required_inclusion(domain, "state", @domain_states, "#{path}.state")
        |> validate_optional_boolean(domain, "persistent", "#{path}.persistent")
        |> validate_optional_positive_integer(domain, "vcpus", "#{path}.vcpus")
        |> validate_optional_positive_integer(domain, "memory_mib", "#{path}.memory_mib")
        |> validate_domain_devices(domain, "disks", path, &validate_domain_disk/3)
        |> validate_domain_devices(domain, "interfaces", path, &validate_domain_interface/3)

      {{:ok, _invalid}, "vm"} ->
        [error("#{path}.domain", "must be an object") | errors]

      {{:ok, _domain}, _other} ->
        [error("#{path}.domain", "is only allowed for a vm") | errors]
    end
  end

  defp validate_domain_devices(errors, domain, key, path, validate) do
    case Map.get(domain, key) do
      nil ->
        errors

      devices when is_list(devices) and length(devices) > @max_domain_devices ->
        [error("#{path}.#{key}", "must have at most #{@max_domain_devices} entries") | errors]

      devices when is_list(devices) ->
        devices
        |> Enum.with_index()
        |> Enum.reduce(errors, fn
          {%{} = device, index}, errors ->
            validate.(errors, device, "#{path}.#{key}.#{index}")

          {_invalid, index}, errors ->
            [error("#{path}.#{key}.#{index}", "must be an object") | errors]
        end)

      _invalid ->
        [error("#{path}.#{key}", "must be a list") | errors]
    end
  end

  defp validate_domain_disk(errors, disk, path) do
    errors
    |> validate_required_string(disk, "target", "#{path}.target")
    |> validate_string_length(disk, "target", "#{path}.target")
    |> then(fn errors ->
      Enum.reduce(~w(device bus format source), errors, fn key, errors ->
        validate_optional_string(errors, disk, key, "#{path}.#{key}")
      end)
    end)
  end

  defp validate_domain_interface(errors, interface, path) do
    errors
    |> validate_required_mac(interface, "#{path}.mac_address")
    |> validate_optional_inclusion(interface, "type", @domain_interface_types, "#{path}.type")
    |> then(fn errors ->
      Enum.reduce(~w(source model target), errors, fn key, errors ->
        validate_optional_string(errors, interface, key, "#{path}.#{key}")
      end)
    end)
  end

  defp validate_required_mac(errors, attrs, path) do
    case Map.get(attrs, "mac_address") do
      nil -> [error(path, "is required") | errors]
      _value -> validate_optional_mac(errors, attrs, path)
    end
  end

  defp validate_required_inclusion(errors, attrs, key, accepted_values, path) do
    case Map.fetch(attrs, key) do
      :error -> [error(path, "is required") | errors]
      {:ok, value} -> validate_inclusion_value(errors, value, accepted_values, path)
    end
  end

  defp validate_optional_boolean(errors, attrs, key, path) do
    case Map.get(attrs, key) do
      nil -> errors
      value when is_boolean(value) -> errors
      _invalid -> [error(path, "must be a boolean") | errors]
    end
  end

  # Operator-configured labels the agent sends with each report; triage
  # rules match them, so keys and sizes are bounded like resource labels.
  defp validate_labels(errors, resource, path) do
    case Map.fetch(resource, "labels") do
      :error ->
        errors

      {:ok, %{} = labels} when map_size(labels) > @max_labels ->
        [error("#{path}.labels", "must have at most #{@max_labels} entries") | errors]

      {:ok, %{} = labels} ->
        Enum.reduce(labels, errors, &validate_label(&1, &2, path))

      {:ok, _invalid} ->
        [error("#{path}.labels", "must be an object") | errors]
    end
  end

  defp validate_label({key, value}, errors, path) do
    cond do
      not label_key?(key) ->
        [error("#{path}.labels", "has an invalid key #{inspect(key)}") | errors]

      not is_binary(value) ->
        [error("#{path}.labels.#{key}", "must be a string") | errors]

      String.length(value) > @max_label_value_length ->
        [
          error("#{path}.labels.#{key}", "must be at most #{@max_label_value_length} characters")
          | errors
        ]

      true ->
        errors
    end
  end

  defp label_key?(key) when is_binary(key),
    do: byte_size(key) <= @max_label_key_length and Regex.match?(@label_key_pattern, key)

  defp label_key?(_key), do: false

  # A scoped report whose collector kind is invalid has no expected kind; the
  # collector error already rejects it.
  defp validate_resource_kind(errors, _resource, _path, nil), do: errors

  defp validate_resource_kind(errors, resource, path, kind) do
    case Map.get(resource, "kind") do
      ^kind -> errors
      nil -> [error("#{path}.kind", "is required") | errors]
      _other -> [error("#{path}.kind", "must be #{kind}") | errors]
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
    |> Enum.map(&ResourceIdentifier.normalize_value("mac_address", &1))
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
        errors
        |> validate_unique_interface_names(interfaces, "#{path}.interfaces")
        |> validate_interface_entries(interfaces, path)

      _invalid ->
        [error("#{path}.interfaces", "must be a list") | errors]
    end
  end

  defp validate_interface_entries(errors, interfaces, path) do
    interfaces
    |> Enum.with_index()
    |> Enum.reduce(errors, fn {interface, index}, errors ->
      validate_interface(errors, interface, "#{path}.interfaces.#{index}")
    end)
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
    |> validate_interface_routing_domain(interface, path)
    |> validate_interface_vlans(interface, path)
    |> validate_interface_neighbors(interface, path)
    |> validate_interface_relationships(interface, path)
  end

  defp validate_interface(errors, _interface, path) do
    [error(path, "must be an object") | errors]
  end

  defp validate_unique_interface_names(errors, interfaces, path) do
    names =
      interfaces
      |> Enum.flat_map(fn
        %{"name" => name} when is_binary(name) -> [String.trim(name)]
        _invalid -> []
      end)

    if length(names) == length(Enum.uniq(names)),
      do: errors,
      else: [error(path, "must not contain duplicate normalized interface names") | errors]
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

  # A routing-domain claim (RFD 4, "Observation correlation"): an object
  # naming the source-local domain, or null to withdraw the source's claim.
  # Absent says nothing.
  defp validate_interface_routing_domain(errors, interface, path) do
    path = "#{path}.routing_domain"

    case Map.fetch(interface, "routing_domain") do
      :error ->
        errors

      {:ok, nil} ->
        errors

      {:ok, %{} = domain} ->
        errors
        |> validate_routing_domain_key(domain, "#{path}.key")
        |> validate_optional_routing_domain_string(domain, "route_distinguisher", path)
        |> validate_optional_map(domain, "metadata", "#{path}.metadata")

      {:ok, _invalid} ->
        [error(path, "must be an object or null") | errors]
    end
  end

  defp validate_routing_domain_key(errors, domain, path) do
    case Map.get(domain, "key") do
      key when is_binary(key) ->
        cond do
          String.trim(key) == "" ->
            [error(path, "must not be blank") | errors]

          length(String.codepoints(key)) > 255 ->
            [error(path, "must be at most 255 code points") | errors]

          true ->
            errors
        end

      _missing ->
        [error(path, "must be a string") | errors]
    end
  end

  defp validate_optional_routing_domain_string(errors, domain, field, path) do
    case Map.get(domain, field) do
      nil -> errors
      value when is_binary(value) and byte_size(value) <= 255 -> errors
      _invalid -> [error("#{path}.#{field}", "must be a string of at most 255 bytes") | errors]
    end
  end

  defp validate_interface_vlans(errors, interface, path) do
    errors =
      validate_optional_inclusion(
        errors,
        interface,
        "vlan_mode",
        @interface_vlan_modes,
        "#{path}.vlan_mode"
      )

    case Map.fetch(interface, "vlans") do
      :error ->
        errors

      {:ok, memberships} when is_list(memberships) ->
        errors =
          memberships
          |> Enum.with_index()
          |> Enum.reduce(errors, fn {membership, index}, errors ->
            validate_interface_vlan(errors, membership, "#{path}.vlans.#{index}")
          end)

        errors
        |> validate_effective_untagged_membership(path, memberships)
        |> validate_unique_vlan_memberships(path, memberships)
        |> validate_access_memberships(interface, path, memberships)

      {:ok, _invalid} ->
        [error("#{path}.vlans", "must be a list") | errors]
    end
  end

  defp validate_interface_vlan(errors, %{} = membership, path) do
    errors
    |> validate_required_vid(membership, "#{path}.vid")
    |> validate_optional_source_local_vlan_key(membership, "#{path}.key")
    |> validate_optional_non_blank_string(membership, "scope", "#{path}.scope")
    |> validate_optional_codepoint_length(membership, "scope", "#{path}.scope")
    |> validate_optional_inclusion(
      membership,
      "tagging_mode",
      @vlan_tagging_modes,
      "#{path}.tagging_mode"
    )
    |> validate_required_tagging_mode(membership, "#{path}.tagging_mode")
    |> validate_optional_non_nil_map(membership, "metadata", "#{path}.metadata")
  end

  defp validate_interface_vlan(errors, _membership, path),
    do: [error(path, "must be an object") | errors]

  defp validate_required_vid(errors, membership, path) do
    case Map.get(membership, "vid") do
      vid when is_integer(vid) and vid in 1..4094 -> errors
      nil -> [error(path, "is required") | errors]
      _invalid -> [error(path, "must be an integer from 1 through 4094") | errors]
    end
  end

  defp validate_required_tagging_mode(errors, membership, path) do
    if Map.has_key?(membership, "tagging_mode"),
      do: errors,
      else: [error(path, "is required") | errors]
  end

  defp validate_access_memberships(errors, %{"vlan_mode" => "access"}, path, memberships) do
    if length(memberships) <= 1 and
         Enum.all?(memberships, &(is_map(&1) and &1["tagging_mode"] == "untagged")) do
      errors
    else
      [error("#{path}.vlans", "access mode allows at most one untagged VLAN") | errors]
    end
  end

  defp validate_access_memberships(errors, _interface, _path, _memberships), do: errors

  defp validate_effective_untagged_membership(errors, path, memberships) do
    if Enum.count(memberships, &(is_map(&1) and &1["tagging_mode"] == "untagged")) <= 1,
      do: errors,
      else: [error("#{path}.vlans", "allows at most one untagged VLAN") | errors]
  end

  defp validate_unique_vlan_memberships(errors, path, memberships) do
    keys =
      memberships
      |> Enum.filter(&valid_vlan_membership_identity?/1)
      |> Enum.map(&source_local_vlan_key/1)

    if length(keys) == length(Enum.uniq(keys)),
      do: errors,
      else: [error("#{path}.vlans", "must not contain duplicate source-local VLANs") | errors]
  end

  defp validate_interface_relationships(errors, interface, path) do
    case Map.fetch(interface, "relationships") do
      :error ->
        errors

      {:ok, relationships} when is_list(relationships) ->
        relationships
        |> Enum.with_index()
        |> Enum.reduce(errors, fn {relationship, index}, errors ->
          validate_interface_relationship(errors, relationship, "#{path}.relationships.#{index}")
        end)
        |> validate_distinct_relationship_targets(interface, path, relationships)

      {:ok, _invalid} ->
        [error("#{path}.relationships", "must be a list") | errors]
    end
  end

  defp validate_interface_neighbors(errors, interface, path) do
    case Map.fetch(interface, "neighbors") do
      :error ->
        errors

      {:ok, neighbors} when is_list(neighbors) ->
        neighbors
        |> Enum.with_index()
        |> Enum.reduce(errors, fn {neighbor, index}, errors ->
          validate_interface_neighbor(errors, neighbor, "#{path}.neighbors.#{index}")
        end)
        |> validate_unique_interface_neighbors(path, neighbors)

      {:ok, _invalid} ->
        [error("#{path}.neighbors", "must be a list") | errors]
    end
  end

  defp validate_interface_neighbor(errors, %{} = neighbor, path) do
    errors
    |> validate_required_string(neighbor, "protocol", "#{path}.protocol")
    |> validate_optional_inclusion(neighbor, "protocol", @neighbor_protocols, "#{path}.protocol")
    |> validate_required_string(neighbor, "remote_chassis_id", "#{path}.remote_chassis_id")
    |> validate_string_length(neighbor, "remote_chassis_id", "#{path}.remote_chassis_id")
    |> validate_optional_codepoint_length(
      neighbor,
      "remote_chassis_id",
      "#{path}.remote_chassis_id"
    )
    |> validate_optional_inclusion(
      neighbor,
      "remote_chassis_id_kind",
      @neighbor_chassis_id_kinds,
      "#{path}.remote_chassis_id_kind"
    )
    |> validate_optional_non_blank_string(
      neighbor,
      "remote_system_name",
      "#{path}.remote_system_name"
    )
    |> validate_optional_codepoint_length(
      neighbor,
      "remote_system_name",
      "#{path}.remote_system_name"
    )
    |> validate_required_string(neighbor, "remote_port_id", "#{path}.remote_port_id")
    |> validate_string_length(neighbor, "remote_port_id", "#{path}.remote_port_id")
    |> validate_optional_codepoint_length(neighbor, "remote_port_id", "#{path}.remote_port_id")
    |> validate_optional_inclusion(
      neighbor,
      "remote_port_id_kind",
      @neighbor_port_id_kinds,
      "#{path}.remote_port_id_kind"
    )
    |> validate_optional_non_blank_string(
      neighbor,
      "remote_port_description",
      "#{path}.remote_port_description"
    )
    |> validate_optional_codepoint_length(
      neighbor,
      "remote_port_description",
      "#{path}.remote_port_description"
    )
    |> validate_neighbor_identifier_value(
      neighbor,
      "remote_chassis_id_kind",
      "remote_chassis_id",
      path
    )
    |> validate_neighbor_identifier_value(
      neighbor,
      "remote_port_id_kind",
      "remote_port_id",
      path
    )
    |> validate_neighbor_ttl(neighbor, "#{path}.ttl_seconds")
    |> validate_optional_non_nil_map(neighbor, "metadata", "#{path}.metadata")
  end

  defp validate_interface_neighbor(errors, _neighbor, path),
    do: [error(path, "must be an object") | errors]

  defp validate_unique_interface_neighbors(errors, path, neighbors) do
    identities =
      Enum.flat_map(neighbors, fn
        %{
          "protocol" => protocol,
          "remote_chassis_id" => chassis_id,
          "remote_port_id" => port_id
        } = neighbor
        when is_binary(protocol) and is_binary(chassis_id) and is_binary(port_id) ->
          chassis_kind = Map.get(neighbor, "remote_chassis_id_kind")
          port_kind = Map.get(neighbor, "remote_port_id_kind")

          [
            {
              protocol,
              chassis_kind,
              NeighborIdentifier.normalize_chassis(chassis_kind, chassis_id),
              port_kind,
              NeighborIdentifier.normalize_port(port_kind, port_id)
            }
          ]

        _invalid ->
          []
      end)

    if length(identities) == length(Enum.uniq(identities)),
      do: errors,
      else: [error("#{path}.neighbors", "must not contain duplicate endpoints") | errors]
  end

  defp validate_neighbor_ttl(errors, neighbor, path) do
    case Map.fetch(neighbor, "ttl_seconds") do
      {:ok, value} when is_integer(value) and value in 1..65_535 -> errors
      {:ok, _invalid} -> [error(path, "must be an integer from 1 through 65535") | errors]
      :error -> [error(path, "is required") | errors]
    end
  end

  defp validate_neighbor_identifier_value(errors, neighbor, kind_key, value_key, path) do
    kind = Map.get(neighbor, kind_key)
    value = Map.get(neighbor, value_key)
    errors = validate_neighbor_identifier_format(errors, kind, value, value_key, path)
    normalized = normalize_neighbor_identifier(kind, value, value_key)

    if normalized && length(String.codepoints(normalized)) > 255,
      do: [
        error("#{path}.#{value_key}", "normalized value must be at most 255 characters") | errors
      ],
      else: errors
  end

  defp validate_neighbor_identifier_format(errors, "mac_address", value, value_key, path)
       when is_binary(value) do
    if NeighborIdentifier.mac_address?(value),
      do: errors,
      else: [error("#{path}.#{value_key}", "must be a MAC address") | errors]
  end

  defp validate_neighbor_identifier_format(errors, "network_address", value, value_key, path)
       when is_binary(value) do
    case Inet.cast(String.trim(value)) do
      {:ok, _address} -> errors
      :error -> [error("#{path}.#{value_key}", "must be a network address") | errors]
    end
  end

  defp validate_neighbor_identifier_format(errors, _kind, _value, _value_key, _path),
    do: errors

  defp normalize_neighbor_identifier(_kind, value, _value_key) when not is_binary(value), do: nil

  defp normalize_neighbor_identifier(kind, value, "remote_chassis_id"),
    do: NeighborIdentifier.normalize_chassis(kind, value)

  defp normalize_neighbor_identifier(kind, value, _port_key),
    do: NeighborIdentifier.normalize_port(kind, value)

  defp validate_interface_relationship(errors, %{} = relationship, path) do
    errors
    |> validate_required_string(relationship, "target", "#{path}.target")
    |> validate_string_length(relationship, "target", "#{path}.target")
    |> validate_optional_inclusion(
      relationship,
      "kind",
      @interface_relationship_kinds,
      "#{path}.kind"
    )
    |> validate_required_relationship_kind(relationship, "#{path}.kind")
    |> validate_optional_non_nil_map(relationship, "metadata", "#{path}.metadata")
  end

  defp validate_interface_relationship(errors, _relationship, path),
    do: [error(path, "must be an object") | errors]

  defp validate_required_relationship_kind(errors, relationship, path) do
    if Map.has_key?(relationship, "kind"), do: errors, else: [error(path, "is required") | errors]
  end

  defp validate_distinct_relationship_targets(errors, interface, path, relationships) do
    interface_name = Map.get(interface, "name")

    if is_binary(interface_name) and
         Enum.any?(relationships, fn
           %{"target" => target} when is_binary(target) ->
             String.trim(target) == String.trim(interface_name)

           _invalid ->
             false
         end),
       do: [error("#{path}.relationships", "cannot target the same interface") | errors],
       else: errors
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
    Enum.reduce(@host_projection_fields, errors, fn field, errors ->
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

  defp validate_optional_non_nil_map(errors, attrs, key, path) do
    case Map.fetch(attrs, key) do
      :error -> errors
      {:ok, value} when is_map(value) -> errors
      {:ok, _invalid} -> [error(path, "must be an object") | errors]
    end
  end

  defp validate_optional_non_blank_string(errors, attrs, key, path) do
    case Map.fetch(attrs, key) do
      :error ->
        errors

      {:ok, value} when is_binary(value) ->
        errors |> validate_non_blank(path, value) |> validate_string_value(value, path)

      {:ok, _invalid} ->
        [error(path, "must be a string") | errors]
    end
  end

  defp validate_optional_codepoint_length(errors, attrs, key, path) do
    case Map.get(attrs, key) do
      value when is_binary(value) ->
        if String.codepoints(value) |> length() <= @max_agent_string_length,
          do: errors,
          else: [error(path, "must be at most #{@max_agent_string_length} code points") | errors]

      _missing_or_invalid ->
        errors
    end
  end

  defp validate_optional_source_local_vlan_key(errors, membership, path) do
    case Map.fetch(membership, "key") do
      :error ->
        errors

      {:ok, value} when is_binary(value) ->
        value = String.trim(value)

        cond do
          value == "" ->
            [error(path, "must not be blank") | errors]

          byte_size(value) > @max_source_local_vlan_key_bytes ->
            [error(path, "is too large") | errors]

          true ->
            errors
        end

      {:ok, _invalid} ->
        [error(path, "must be a string") | errors]
    end
  end

  defp valid_vlan_membership_identity?(membership) do
    is_map(membership) and is_integer(membership["vid"]) and
      (is_nil(membership["key"]) or is_binary(membership["key"])) and
      (is_nil(membership["scope"]) or is_binary(membership["scope"]))
  end

  defp source_local_vlan_key(membership) do
    normalize_source_local_vlan_key(Map.get(membership, "key")) ||
      "#{normalize_source_scope(Map.get(membership, "scope"))}:#{membership["vid"]}"
  end

  defp normalize_source_local_vlan_key(nil), do: nil
  defp normalize_source_local_vlan_key(key), do: String.trim(key)

  defp normalize_source_scope(nil), do: "default"
  defp normalize_source_scope(scope), do: String.trim(scope)

  defp validate_section_completeness(errors, params) do
    case Map.fetch(params, "section_completeness") do
      :error ->
        errors

      {:ok, completeness} when is_map(completeness) ->
        Enum.reduce(completeness, errors, fn {section, value}, errors ->
          validate_section_completeness_entry(errors, section, value)
        end)

      {:ok, _invalid} ->
        [error("section_completeness", "must be an object") | errors]
    end
  end

  defp validate_section_completeness_entry(errors, section, value) do
    if section in @completeness_sections and is_boolean(value) do
      errors
    else
      [error("section_completeness.#{section}", "must be a supported boolean") | errors]
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

  defp validate_observation_clock(errors, nil), do: errors

  defp validate_observation_clock(errors, observed_at) do
    latest = DateTime.add(Renga.Time.utc_now_ms(), @max_future_observation_skew_seconds, :second)

    if DateTime.compare(observed_at, latest) == :gt,
      do: [error("observed_at", "must not be more than 5 minutes in the future") | errors],
      else: errors
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
