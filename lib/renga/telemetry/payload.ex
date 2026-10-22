defmodule Renga.Telemetry.Payload do
  @moduledoc """
  Validation for telemetry batches (RFD 10, "Measured history").

  A batch is a versioned payload with its own replay ID, apart from
  inventory observations, so it can never be mistaken for one. It names the
  collector that produced it, or none for the installation's own host
  readings, and carries samples that each identify their target, sensor,
  measurement boundary, quantity, unit, sampling window, source mapping, and
  event time.

  A malformed batch is rejected whole. A well-formed sample that is not
  usable evidence, such as a failed read or a unit that does not fit its
  quantity, is accepted as invalid evidence: it tells Renga the series has
  no usable value, which is different from never hearing about it.
  """

  alias Renga.Inventory.AgentPayload
  alias Renga.Power.Reading

  @versions [1]
  @max_batch_bytes 512_000
  @max_samples 2_000
  @max_replay_id_length 255
  @max_name_length 255
  @max_state_length 64
  @max_unit_length 16
  @max_mapping_version 1_000_000
  @max_freshness_seconds 86_400
  # Readings are electrical quantities of real equipment; anything larger is
  # a broken sensor, not a load.
  @max_value Decimal.new("1000000000000")
  @statuses ~w(valid missing failed)
  @collector_kinds ~w(power_poller bmc_power)

  @doc """
  The vocabularies and limits this module enforces, for the OpenAPI
  schemas.
  """
  def contract do
    %{
      versions: @versions,
      max_batch_bytes: @max_batch_bytes,
      max_samples: @max_samples,
      max_replay_id_length: @max_replay_id_length,
      max_name_length: @max_name_length,
      max_state_length: @max_state_length,
      max_unit_length: @max_unit_length,
      max_mapping_version: @max_mapping_version,
      max_freshness_seconds: @max_freshness_seconds,
      statuses: @statuses,
      collector_kinds: @collector_kinds,
      boundaries: Reading.boundaries(),
      quantities: Reading.quantities(),
      units: Reading.units(),
      origins: Reading.origins(),
      coverages: Reading.coverages(),
      legs: Reading.legs(),
      component_kinds: Reading.component_kinds()
    }
  end

  @doc """
  Validates a batch. Returns `{:ok, attrs}` with the replay ID, version,
  collector (`{id, kind}` or `nil`), payload digest, and parsed samples, or
  `{:error, errors}`.
  """
  def validate(params) when is_map(params) do
    errors =
      []
      |> validate_size(params)
      |> validate_version(Map.get(params, "version"))
      |> validate_replay_id(Map.get(params, "replay_id"))

    {collector, errors} = validate_collector(errors, Map.get(params, "collector"))
    {samples, errors} = validate_samples(errors, Map.get(params, "samples"), collector)

    case errors do
      [] ->
        {:ok,
         %{
           version: Map.fetch!(params, "version"),
           replay_id: String.trim(Map.fetch!(params, "replay_id")),
           collector: collector,
           payload_digest: digest(params),
           samples: samples
         }}

      errors ->
        {:error, Enum.reverse(errors)}
    end
  end

  def validate(_params), do: {:error, [error("body", "must be a JSON object")]}

  defp digest(params) do
    :crypto.hash(:sha256, Jason.encode_to_iodata!(params)) |> Base.encode16(case: :lower)
  end

  defp validate_size(errors, params) do
    case Jason.encode(params) do
      {:ok, encoded} when byte_size(encoded) <= @max_batch_bytes ->
        errors

      {:ok, _encoded} ->
        [error("body", "must be at most #{@max_batch_bytes} bytes") | errors]

      {:error, _reason} ->
        [error("body", "must be JSON encodable") | errors]
    end
  end

  defp validate_version(errors, version) when version in @versions, do: errors
  defp validate_version(errors, nil), do: [error("version", "is required") | errors]

  defp validate_version(errors, _version),
    do: [error("version", "must be one of #{Enum.join(@versions, ", ")}") | errors]

  defp validate_replay_id(errors, replay_id) do
    validate_name(errors, replay_id, "replay_id", @max_replay_id_length)
  end

  defp validate_collector(errors, nil), do: {nil, errors}

  defp validate_collector(errors, %{"id" => id, "kind" => kind}) when is_binary(id) do
    %{max_collector_id_length: max_length, collector_id_pattern: pattern} =
      AgentPayload.contract()

    id = String.trim(id)

    errors =
      cond do
        String.length(id) > max_length ->
          [error("collector.id", "must be at most #{max_length} characters") | errors]

        not Regex.match?(pattern, id) ->
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

    if kind in @collector_kinds,
      do: {{id, kind}, errors},
      else: {nil, [error("collector.kind", "must be one of #{list(@collector_kinds)}") | errors]}
  end

  defp validate_collector(errors, %{}),
    do: {nil, [error("collector", "must have a string id and a kind") | errors]}

  defp validate_collector(errors, _invalid),
    do: {nil, [error("collector", "must be an object") | errors]}

  defp validate_samples(errors, samples, collector) when is_list(samples) do
    cond do
      samples == [] ->
        {[], [error("samples", "must not be empty") | errors]}

      length(samples) > @max_samples ->
        {[], [error("samples", "must have at most #{@max_samples} entries") | errors]}

      true ->
        {samples, errors} =
          samples
          |> Enum.with_index()
          |> Enum.reduce({[], errors}, fn {sample, index}, {samples, errors} ->
            case validate_sample(sample, "samples[#{index}]", collector) do
              {:ok, sample} -> {[sample | samples], errors}
              {:error, sample_errors} -> {samples, sample_errors ++ errors}
            end
          end)

        {Enum.reverse(samples), errors}
    end
  end

  defp validate_samples(errors, nil, _collector),
    do: {[], [error("samples", "is required") | errors]}

  defp validate_samples(errors, _invalid, _collector),
    do: {[], [error("samples", "must be an array") | errors]}

  defp validate_sample(%{} = sample, path, collector) do
    {window_start, window_end, errors} = window(Map.get(sample, "window"), "#{path}.window")
    {event_at, errors} = timestamp(errors, Map.get(sample, "event_at"), "#{path}.event_at")
    {component, errors} = component(errors, Map.get(sample, "component"), "#{path}.component")

    errors =
      errors
      |> validate_target(Map.get(sample, "target"), "#{path}.target", collector)
      |> validate_name(Map.get(sample, "sensor"), "#{path}.sensor", @max_name_length)
      |> member(Map.get(sample, "boundary"), Reading.boundaries(), "#{path}.boundary")
      |> member(Map.get(sample, "quantity"), Reading.quantities(), "#{path}.quantity")
      |> optional_member(Map.get(sample, "status"), @statuses, "#{path}.status")
      |> optional_member(Map.get(sample, "origin"), Reading.origins(), "#{path}.origin")
      |> optional_member(Map.get(sample, "coverage"), Reading.coverages(), "#{path}.coverage")
      |> validate_leg(Map.get(sample, "leg"), Map.get(sample, "boundary"), "#{path}.leg")
      |> validate_unit(Map.get(sample, "unit"), "#{path}.unit")
      |> validate_value(Map.get(sample, "value"), "#{path}.value")
      |> validate_state(Map.get(sample, "state"), "#{path}.state")
      |> validate_mapping(Map.get(sample, "mapping"), "#{path}.mapping")
      |> validate_freshness(Map.get(sample, "fresh_for_seconds"), "#{path}.fresh_for_seconds")

    case errors do
      [] ->
        {:ok,
         %{
           target: trim(Map.get(sample, "target")),
           sensor: String.trim(Map.fetch!(sample, "sensor")),
           boundary: Map.fetch!(sample, "boundary"),
           quantity: Map.fetch!(sample, "quantity"),
           unit: Map.get(sample, "unit"),
           leg: Map.get(sample, "leg"),
           component: component,
           coverage: Map.get(sample, "coverage"),
           origin: Map.get(sample, "origin") || "native",
           status: Map.get(sample, "status") || "valid",
           value: Map.get(sample, "value"),
           state: trim(Map.get(sample, "state")),
           window_start: window_start,
           window_end: window_end,
           event_at: event_at,
           mapping_name: String.trim(get_in(sample, ["mapping", "name"])),
           mapping_version: get_in(sample, ["mapping", "version"]),
           fresh_for_seconds: Map.fetch!(sample, "fresh_for_seconds")
         }}

      errors ->
        {:error, errors}
    end
  end

  defp validate_sample(_sample, path, _collector),
    do: {:error, [error(path, "must be an object")]}

  # A collector's readings are about one of its targets; a host agent's are
  # about its own host, which needs no key.
  defp validate_target(errors, nil, path, {_id, _kind}),
    do: [error(path, "is required for a collector's readings") | errors]

  defp validate_target(errors, target, path, {_id, _kind}),
    do: validate_name(errors, target, path, @max_name_length)

  defp validate_target(errors, nil, _path, nil), do: errors

  defp validate_target(errors, _target, path, nil),
    do: [error(path, "must be absent for the host's own readings") | errors]

  defp validate_leg(errors, nil, "leg", path),
    do: [error(path, "is required for a leg reading") | errors]

  defp validate_leg(errors, nil, _boundary, _path), do: errors

  defp validate_leg(errors, leg, "leg", path), do: member(errors, leg, Reading.legs(), path)

  defp validate_leg(errors, _leg, _boundary, path),
    do: [error(path, "is allowed only for a leg reading") | errors]

  defp validate_unit(errors, nil, _path), do: errors

  defp validate_unit(errors, unit, path) when is_binary(unit) do
    if String.length(unit) <= @max_unit_length,
      do: errors,
      else: [error(path, "must be at most #{@max_unit_length} characters") | errors]
  end

  defp validate_unit(errors, _unit, path), do: [error(path, "must be a string") | errors]

  defp validate_value(errors, value, _path) when is_nil(value) or is_number(value), do: errors
  defp validate_value(errors, _value, path), do: [error(path, "must be a number") | errors]

  defp validate_state(errors, nil, _path), do: errors

  defp validate_state(errors, state, path) when is_binary(state) do
    if String.length(state) <= @max_state_length,
      do: errors,
      else: [error(path, "must be at most #{@max_state_length} characters") | errors]
  end

  defp validate_state(errors, _state, path), do: [error(path, "must be a string") | errors]

  defp validate_mapping(errors, %{"name" => name, "version" => version}, path) do
    errors = validate_name(errors, name, "#{path}.name", @max_name_length)

    if is_integer(version) and version >= 1 and version <= @max_mapping_version,
      do: errors,
      else: [
        error("#{path}.version", "must be an integer from 1 to #{@max_mapping_version}")
        | errors
      ]
  end

  defp validate_mapping(errors, _mapping, path),
    do: [error(path, "must be an object with a name and a version") | errors]

  defp validate_freshness(errors, seconds, _path)
       when is_integer(seconds) and seconds >= 1 and seconds <= @max_freshness_seconds,
       do: errors

  defp validate_freshness(errors, _seconds, path),
    do: [error(path, "must be an integer from 1 to #{@max_freshness_seconds}") | errors]

  defp component(errors, nil, _path), do: {nil, errors}

  defp component(errors, %{"kind" => kind, "name" => name}, path) do
    errors =
      errors
      |> member(kind, Reading.component_kinds(), "#{path}.kind")
      |> validate_name(name, "#{path}.name", @max_name_length)

    {%{kind: kind, name: if(is_binary(name), do: String.trim(name), else: name)}, errors}
  end

  defp component(errors, _component, path),
    do: {nil, [error(path, "must be an object with a kind and a name") | errors]}

  defp window(%{"start" => start, "end" => finish}, path) do
    {window_start, errors} = timestamp([], start, "#{path}.start")
    {window_end, errors} = timestamp(errors, finish, "#{path}.end")

    if window_start && window_end && DateTime.compare(window_start, window_end) == :gt,
      do: {nil, nil, [error(path, "must not end before it starts") | errors]},
      else: {window_start, window_end, errors}
  end

  defp window(_window, path),
    do: {nil, nil, [error(path, "must be an object with a start and an end")]}

  defp timestamp(errors, value, path) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> {Renga.Time.floor_to_millisecond(datetime), errors}
      {:error, _reason} -> {nil, [error(path, "must be an ISO 8601 timestamp") | errors]}
    end
  end

  defp timestamp(errors, nil, path), do: {nil, [error(path, "is required") | errors]}
  defp timestamp(errors, _value, path), do: {nil, [error(path, "must be a string") | errors]}

  defp validate_name(errors, value, path, max_length) when is_binary(value) do
    value = String.trim(value)

    cond do
      value == "" -> [error(path, "must not be blank") | errors]
      String.length(value) > max_length -> [error(path, too_long(max_length)) | errors]
      true -> errors
    end
  end

  defp validate_name(errors, nil, path, _max_length), do: [error(path, "is required") | errors]

  defp validate_name(errors, _value, path, _max_length),
    do: [error(path, "must be a string") | errors]

  defp member(errors, value, allowed, path) do
    if value in allowed,
      do: errors,
      else: [error(path, "must be one of #{list(allowed)}") | errors]
  end

  defp optional_member(errors, nil, _allowed, _path), do: errors
  defp optional_member(errors, value, allowed, path), do: member(errors, value, allowed, path)

  @doc """
  Judges a parsed sample as evidence: `{validity, value, state}`. A reported
  failure or missing value stays one; a value is usable only in the unit its
  quantity is measured in and within physical bounds.
  """
  def evidence(%{status: "missing"}), do: {"missing", nil, nil}
  def evidence(%{status: "failed"}), do: {"failed", nil, nil}

  def evidence(%{quantity: "state", unit: nil, value: nil, state: state})
      when is_binary(state) and state != "",
      do: {"valid", nil, state}

  def evidence(%{quantity: "state"}), do: {"invalid", nil, nil}

  def evidence(%{quantity: quantity, unit: unit, value: value, state: nil})
      when is_number(value) do
    value = to_decimal(value)

    if unit == Map.fetch!(Reading.units(), quantity) and in_bounds?(quantity, value),
      do: {"valid", value, nil},
      else: {"invalid", nil, nil}
  end

  def evidence(%{}), do: {"invalid", nil, nil}

  defp to_decimal(value) when is_integer(value), do: Decimal.new(value)
  defp to_decimal(value) when is_float(value), do: Decimal.from_float(value)

  defp in_bounds?("power_factor", value),
    do: Decimal.gt?(value, 0) and not Decimal.gt?(value, 1)

  defp in_bounds?(_quantity, value),
    do: not Decimal.negative?(value) and Decimal.lt?(value, @max_value)

  defp trim(nil), do: nil
  defp trim(value) when is_binary(value), do: String.trim(value)

  defp too_long(max_length), do: "must be at most #{max_length} characters"
  defp list(values), do: Enum.join(values, ", ")
  defp error(path, message), do: %{path: path, message: message}
end
