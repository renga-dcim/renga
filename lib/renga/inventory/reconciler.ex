defmodule Renga.Inventory.Reconciler do
  @moduledoc """
  Reconciles immutable host observations into source-neutral inventory.

  Stable identifiers decide identity before names. Hostname and FQDN are only
  eligible when an observation has no strong identifier, which prevents a
  recycled name from merging two different machines.

  A collector stream's report (RFD 11) reconciles each of its derived
  single-resource observations the same way, except that only stable
  identifiers match: a switch or VM name, or a MAC address alone, never merges
  it with another resource. The report then updates its stream's targets.
  """

  import Ecto.Query, warn: false

  alias Renga.Accounts.Scope
  alias Renga.Inventory
  alias Renga.Inventory.AgentPayload
  alias Renga.Inventory.Collectors
  alias Renga.Inventory.Host
  alias Renga.Inventory.Interface
  alias Renga.Inventory.Observation
  alias Renga.Inventory.ObservationReconciliation
  alias Renga.Inventory.Reconciler.Projections
  alias Renga.Inventory.Resource
  alias Renga.Inventory.ResourceIdentifier
  alias Renga.Inventory.Source
  alias Renga.Repo

  @strong_identifier_kinds ~w(serial_number dmi_uuid machine_id)
  @weak_identifier_kinds ~w(hostname fqdn)
  @identity_interface_kinds ~w(ethernet)
  # What collector streams report (RFD 11). Only stable identifiers match
  # them, whichever side reports first.
  @collector_resource_kinds ~w(switch vm)

  @doc """
  Reconciles one scoped observation and records its immutable processing result.
  """
  def reconcile(%Scope{} = scope, %Observation{} = observation, opts \\ []) do
    authorize = Keyword.get(opts, :authorize, fn -> :ok end)

    try do
      do_reconcile(scope, observation, authorize)
    rescue
      exception -> record_unexpected_failure(scope, observation, exception, authorize)
    end
  end

  @doc """
  Reconciles an observation only when it has no terminal processing result.

  This is the ingestion path. The organization lock makes the terminal-result
  check and first attempt allocation atomic, while `reconcile/2` remains the
  explicit retry path for repaired failures.
  """
  def reconcile_once(%Scope{} = scope, %Observation{} = observation, opts \\ []) do
    authorize = Keyword.get(opts, :authorize, fn -> :ok end)

    try do
      reconcile_once(scope, observation, authorize, %{})
    rescue
      exception -> record_unexpected_failure_once(scope, observation, exception, authorize)
    end
  end

  defp reconcile_once(scope, observation, authorize, failed) do
    Repo.transaction(fn ->
      authorize.()
      Inventory.lock_organization!(scope.organization_id)

      case latest_result(scope, observation.id) do
        nil -> perform_reconciliation(scope, observation, failed)
        result -> result_to_reconciliation(scope, result)
      end
    end)
    |> case do
      {:ok, result} ->
        result

      {:error, {:resource_failed, derived, exception}} ->
        failed = fail_resource!(scope, derived, exception, authorize, failed)
        reconcile_once(scope, observation, authorize, failed)

      {:error, reason} ->
        record_unexpected_failure_once(scope, observation, reason, authorize)
    end
  end

  defp do_reconcile(scope, observation, authorize, failed \\ %{}) do
    Repo.transaction(fn ->
      authorize.()
      Inventory.lock_organization!(scope.organization_id)
      perform_reconciliation(scope, observation, failed)
    end)
    |> case do
      {:ok, result} ->
        result

      {:error, {:resource_failed, derived, exception}} ->
        failed = fail_resource!(scope, derived, exception, authorize, failed)
        do_reconcile(scope, observation, authorize, failed)

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Records the failure of the one resource that raised, then lets the report
  # run again without it. Another run of the same report may have reconciled
  # the resource since this one rolled back; its committed success stands and
  # is not superseded. Each rerun settles one more resource, so a report runs
  # at most once per resource it carries.
  defp fail_resource!(scope, derived, exception, authorize, failed) do
    attrs = unexpected_failure_attrs(exception)

    {:ok, outcome} =
      Repo.transaction(fn ->
        authorize.()
        Inventory.lock_organization!(scope.organization_id)

        case latest_result(scope, derived.id) do
          %{status: "succeeded"} -> :succeeded
          _none_or_failed -> create_failure(scope, derived, attrs)
        end
      end)

    case outcome do
      :succeeded -> failed
      {:error, _result} -> Map.put(failed, derived.id, true)
    end
  end

  defp perform_reconciliation(scope, observation, failed) do
    if report?(observation),
      do: perform_report_reconciliation(scope, observation, failed),
      else: perform_resource_reconciliation(scope, observation)
  end

  defp report?(%Observation{parent_observation_id: nil, payload: payload}),
    do: AgentPayload.scoped_report?(payload)

  defp report?(%Observation{}), do: false

  # Each derived observation reconciles once; a retry of the report retries
  # only the ones that have not succeeded. One resource failing, such as an
  # ambiguous identity, does not hold back the others, but it does stop its
  # target from retiring anything. Resources in `failed` raised earlier in this
  # call, so their recorded failure stands for this run.
  defp perform_report_reconciliation(scope, report, failed) do
    source = Inventory.get_source!(scope, report.source_id)
    started_at = Renga.Time.utc_now_ms()
    attempt = next_attempt(scope, report.id)

    results =
      scope
      |> Inventory.list_derived_observations(report.id)
      |> Enum.map(fn derived ->
        result =
          case latest_result(scope, derived.id) do
            %{status: "succeeded"} = result ->
              result_to_reconciliation(scope, result)

            %{} = result when is_map_key(failed, derived.id) ->
              {:error, result}

            _none_or_failed ->
              isolated_resource_reconciliation(derived, fn ->
                perform_resource_reconciliation(scope, derived)
              end)
          end

        {derived, result}
      end)

    withdrawn = Collectors.apply_report!(scope, source, report, results)

    {:ok, _result} =
      Inventory.create_observation_reconciliation(scope, report.id, %{
        status: "succeeded",
        attempt: attempt,
        metadata: %{
          "resources" => Enum.map(results, &report_resource_result/1),
          "withdrawn_resource_ids" => withdrawn
        },
        started_at: started_at,
        completed_at: Renga.Time.utc_now_ms()
      })

    {:ok, report_resources(results), Enum.any?(results, &match?({_, {:ok, _, true}}, &1))}
  end

  # An unexpected failure, such as a database error, stays with its own
  # resource: the report's transaction rolls back, and the caller records this
  # resource as failed and runs the report again. A savepoint cannot undo it,
  # since a failure inside a nested transaction aborts the whole transaction.
  # A lost connection fails the whole report.
  defp isolated_resource_reconciliation(derived, reconcile) do
    reconcile.()
  rescue
    exception in DBConnection.ConnectionError ->
      reraise exception, __STACKTRACE__

    exception ->
      Repo.rollback({:resource_failed, derived, exception})
  end

  defp report_resource_result({derived, {:ok, resource, _discovered?}}),
    do: %{"observation_id" => derived.id, "status" => "succeeded", "resource_id" => resource.id}

  defp report_resource_result({derived, {:error, result}}),
    do: %{"observation_id" => derived.id, "status" => "failed", "errors" => result.errors}

  defp report_resources(results) do
    for {_derived, {:ok, resource, _discovered?}} <- results, uniq: true, do: resource
  end

  defp perform_resource_reconciliation(scope, observation) do
    source = Inventory.get_source!(scope, observation.source_id)
    identifiers = observation_identifiers(observation.payload)
    started_at = Renga.Time.utc_now_ms()
    attempt = next_attempt(scope, observation.id)

    case match_resource(scope, identifiers, Source.collector_stream?(source)) do
      {:ok, resource, match} ->
        reconcile_resource(
          scope,
          source,
          observation,
          identifiers,
          resource,
          attempt,
          started_at,
          match
        )

      :none ->
        reconcile_resource(
          scope,
          source,
          observation,
          identifiers,
          nil,
          attempt,
          started_at,
          %{"strategy" => "discovered"}
        )

      {:error, candidates} ->
        reconcile_claims(scope, source.id, observation, nil, %{})
        result = record_ambiguous(scope, observation, attempt, started_at, candidates)
        {:error, result}
    end
  end

  defp latest_result(scope, observation_id) do
    scope
    |> Inventory.list_observation_reconciliations(observation_id)
    |> List.last()
  end

  defp result_to_reconciliation(scope, %{status: "succeeded", matched_resource_id: nil} = result) do
    resources =
      for %{"status" => "succeeded", "resource_id" => id} <- result.metadata["resources"] || [],
          uniq: true,
          do: Inventory.get_resource!(scope, id)

    {:ok, resources, false}
  end

  defp result_to_reconciliation(scope, %{status: "succeeded"} = result) do
    {:ok, Inventory.get_resource!(scope, result.matched_resource_id), false}
  end

  defp result_to_reconciliation(_scope, result), do: {:error, result}

  defp record_unexpected_failure_once(scope, observation, reason, authorize) do
    attrs = unexpected_failure_attrs(reason)

    Repo.transaction(fn ->
      authorize.()
      Inventory.lock_organization!(scope.organization_id)

      case latest_result(scope, observation.id) do
        nil -> create_failure(scope, observation, attrs)
        result -> result_to_reconciliation(scope, result)
      end
    end)
    |> case do
      {:ok, result} -> result
      {:error, error} -> {:error, error}
    end
  end

  defp create_failure(scope, observation, attrs) do
    attrs = Map.put(attrs, :attempt, next_attempt(scope, observation.id))

    case Inventory.create_observation_reconciliation(scope, observation.id, attrs) do
      {:ok, result} -> {:error, result}
      {:error, changeset} -> Repo.rollback(changeset)
    end
  end

  defp record_unexpected_failure(scope, observation, exception, authorize) do
    record_serialized_failure(
      scope,
      observation,
      unexpected_failure_attrs(exception),
      authorize
    )
  end

  defp unexpected_failure_attrs(reason) do
    now = Renga.Time.utc_now_ms()

    %{
      status: "failed",
      errors: %{"processing" => "projection_failed"},
      metadata: %{"exception" => failure_type(reason)},
      started_at: now,
      completed_at: now
    }
  end

  defp failure_type(%{__struct__: module}) when is_atom(module) do
    module |> Module.split() |> Enum.join(".")
  end

  defp failure_type(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp failure_type(_reason), do: "unknown"

  defp record_serialized_failure(scope, observation, attrs, authorize, retries \\ 1) do
    Repo.transaction(fn ->
      authorize.()
      Inventory.lock_organization!(scope.organization_id)

      case Inventory.create_observation_reconciliation(
             scope,
             observation.id,
             Map.put(attrs, :attempt, next_attempt(scope, observation.id))
           ) do
        {:ok, result} -> result
        {:error, changeset} -> Repo.rollback(changeset)
      end
    end)
    |> case do
      {:ok, result} ->
        {:error, result}

      {:error, changeset} when retries > 0 ->
        if attempt_conflict?(changeset) do
          record_serialized_failure(scope, observation, attrs, authorize, retries - 1)
        else
          {:error, changeset}
        end

      {:error, changeset} ->
        {:error, changeset}
    end
  end

  defp attempt_conflict?(%Ecto.Changeset{} = changeset) do
    Enum.any?(changeset.errors, fn {_field, {_message, metadata}} ->
      metadata[:constraint] == :unique and
        metadata[:constraint_name] == "observation_reconciliations_observation_attempt_index"
    end)
  end

  defp attempt_conflict?(_reason), do: false

  defp reconcile_resource(
         scope,
         source,
         observation,
         identifiers,
         matched_resource,
         attempt,
         started_at,
         match
       ) do
    {resource, discovered?} =
      ensure_resource(scope, observation, identifiers, matched_resource)

    canonical_identifiers = reconcile_identifiers(scope, resource, identifiers)
    reconcile_claims(scope, source.id, observation, resource, canonical_identifiers)

    freshness_advanced? =
      current_observation?(scope, resource.id, observation) and
        not Collectors.superseded_by_snapshot?(scope, observation, resource.id)

    Projections.reconcile(scope, source, observation, resource,
      allow_new_rows?: freshness_advanced?
    )

    record_success(
      scope,
      source.id,
      observation,
      resource,
      attempt,
      started_at,
      match,
      freshness_advanced?
    )

    # A host agent's report is a claim that keeps a withdrawn resource
    # current, even when it arrives after the withdrawal (RFD 11).
    if source.kind == "host_agent",
      do: :ok = Inventory.keep_claimed_inventory_current!(scope, resource.id, observation)

    {:ok, resource, discovered?}
  end

  # RFD 11: collector resources match only by stable identifiers. MAC
  # addresses are reassigned and cloned with images, and names are reused.
  defp match_resource(scope, identifiers, true = _collector?) do
    stable_identifiers = Enum.filter(identifiers, &(&1.kind in @strong_identifier_kinds))

    scope
    |> identifier_matches(stable_identifiers, @strong_identifier_kinds)
    |> combine_strong_matches()
  end

  defp match_resource(scope, identifiers, false) do
    stable_identifiers = Enum.filter(identifiers, &(&1.kind in @strong_identifier_kinds))
    has_mac? = Enum.any?(identifiers, &(&1.kind == "mac_address"))
    strong_identity? = stable_identifiers != [] or has_mac?

    results =
      identifier_matches(scope, stable_identifiers, @strong_identifier_kinds) ++
        [{"mac_address_set", match_mac_set(scope, identifiers)}]

    case combine_strong_matches(results) do
      :none when strong_identity? -> :none
      :none -> match_weak_identity(scope, identifiers)
      result -> result
    end
  end

  defp match_weak_identity(scope, identifiers) do
    results =
      Enum.map(@weak_identifier_kinds, fn kind ->
        values =
          for identifier <- identifiers, identifier.kind == kind, do: identifier.normalized_value

        {kind, resources_for_current_host_values(scope, kind, values)}
      end)

    combine_strong_matches(results)
  end

  defp identifier_matches(scope, identifiers, kinds) do
    Enum.map(kinds, fn kind ->
      values =
        for identifier <- identifiers, identifier.kind == kind, do: identifier.normalized_value

      {kind, resources_for_identifier_values(scope, kind, values)}
    end)
  end

  defp combine_strong_matches(results) do
    ambiguous_candidates =
      results
      |> Enum.flat_map(fn
        {_strategy, {:error, candidates}} ->
          candidates

        {_strategy, resources} when is_list(resources) and length(resources) > 1 ->
          Enum.map(resources, & &1.id)

        _result ->
          []
      end)
      |> Enum.uniq()

    matches =
      Enum.flat_map(results, fn
        {strategy, {:ok, resource, _metadata}} -> [{strategy, resource}]
        {strategy, [resource]} -> [{strategy, resource}]
        _result -> []
      end)

    matched_resources = matches |> Enum.map(&elem(&1, 1)) |> Enum.uniq_by(& &1.id)

    cond do
      ambiguous_candidates != [] ->
        {:error, ambiguous_candidates}

      length(matched_resources) > 1 ->
        {:error, Enum.map(matched_resources, & &1.id)}

      matched_resources == [] ->
        :none

      true ->
        [{strategy, resource} | _rest] = matches
        {:ok, resource, %{"strategy" => strategy}}
    end
  end

  defp match_mac_set(scope, identifiers) do
    observed_macs =
      identifiers
      |> Enum.filter(&(&1.kind == "mac_address"))
      |> Enum.map(& &1.normalized_value)
      |> MapSet.new()

    if MapSet.size(observed_macs) == 0 do
      :none
    else
      case mac_set_candidates(scope, observed_macs) do
        [] -> :none
        [resource] -> {:ok, resource, %{"strategy" => "mac_address_set"}}
        resources -> {:error, Enum.map(resources, & &1.id)}
      end
    end
  end

  defp mac_set_candidates(scope, observed_macs) do
    Resource
    |> join(:inner, [resource], interface in Interface, on: interface.resource_id == resource.id)
    |> where([resource], resource.organization_id == ^scope.organization_id)
    |> where([resource], resource.kind not in ^@collector_resource_kinds)
    |> where([_resource, interface], interface.status != "not_present")
    |> where([_resource, interface], interface.kind in ^@identity_interface_kinds)
    |> where([_resource, interface], not is_nil(interface.mac_address))
    |> join(:inner, [resource, _interface], candidate in Interface,
      on:
        candidate.resource_id == resource.id and candidate.status != "not_present" and
          candidate.kind in ^@identity_interface_kinds and
          fragment("?::text", candidate.mac_address) in ^MapSet.to_list(observed_macs)
    )
    |> select(
      [resource, interface, _candidate],
      {resource, fragment("?::text", interface.mac_address)}
    )
    |> distinct(true)
    |> Repo.all()
    |> Enum.group_by(fn {resource, _mac} -> resource.id end)
    |> Enum.flat_map(&resource_with_exact_mac_set(&1, observed_macs))
  end

  defp resource_with_exact_mac_set(
         {_resource_id, [{resource, _mac} | _rest] = rows},
         observed_macs
       ) do
    if MapSet.equal?(MapSet.new(rows, &elem(&1, 1)), observed_macs), do: [resource], else: []
  end

  defp resources_for_identifier_values(_scope, _kind, []), do: []

  defp resources_for_identifier_values(scope, kind, values) do
    Resource
    |> join(:inner, [resource], identifier in ResourceIdentifier,
      on: identifier.resource_id == resource.id
    )
    |> where([resource], resource.organization_id == ^scope.organization_id)
    |> where([_resource, identifier], identifier.kind == ^kind)
    |> where([_resource, identifier], identifier.normalized_value in ^values)
    |> distinct(true)
    |> Repo.all()
  end

  defp resources_for_current_host_values(_scope, _kind, []), do: []

  defp resources_for_current_host_values(scope, kind, values) do
    field = String.to_existing_atom(kind)

    Resource
    |> join(:inner, [resource], host in Host, on: host.resource_id == resource.id)
    |> where([resource], resource.organization_id == ^scope.organization_id)
    |> where([resource], resource.kind not in ^@collector_resource_kinds)
    |> where([_resource, host], field(host, ^field) in ^values)
    |> distinct(true)
    |> Repo.all()
  end

  defp ensure_resource(scope, observation, identifiers, nil) do
    kind = Map.get(resource_payload(observation.payload), "kind", "server")
    name = resource_name(scope, observation, identifiers, kind)

    {:ok, resource} =
      Inventory.create_resource(scope, %{
        kind: kind,
        name: name,
        display_name: display_name(identifiers),
        lifecycle_state: "unknown"
      })

    {resource, true}
  end

  defp ensure_resource(_scope, _observation, _identifiers, %Resource{} = resource),
    do: {resource, false}

  defp reconcile_identifiers(scope, resource, identifiers) do
    existing = Inventory.list_resource_identifiers(scope, resource.id)

    Enum.reduce(
      identifiers,
      Map.new(existing, &{{&1.kind, &1.normalized_value}, &1}),
      fn identifier, canonical ->
        key = {identifier.kind, identifier.normalized_value}

        case Map.fetch(canonical, key) do
          {:ok, _existing} ->
            canonical

          :error ->
            {:ok, created} =
              Inventory.create_reconciled_resource_identifier(scope, resource.id, %{
                kind: identifier.kind,
                value: identifier.value
              })

            Map.put(canonical, key, created)
        end
      end
    )
  end

  defp reconcile_claims(scope, source_id, observation, resource, canonical_identifiers) do
    observation.payload
    |> observation_identifiers()
    |> Enum.each(fn identifier ->
      canonical = Map.get(canonical_identifiers, {identifier.kind, identifier.normalized_value})

      {:ok, _claim} =
        Inventory.create_resource_identifier_claim(scope, source_id, observation.id, %{
          kind: identifier.kind,
          value: identifier.value,
          confidence: confidence(identifier.kind),
          resource_id: resource && resource.id,
          resource_identifier_id: canonical && canonical.id
        })
    end)
  end

  defp record_success(
         scope,
         source_id,
         observation,
         resource,
         attempt,
         started_at,
         match,
         freshness_advanced?
       ) do
    completed_at = Renga.Time.utc_now_ms()
    previous_events = Inventory.list_change_events(scope, resource.id)

    if previous_events == [] do
      {:ok, _event} =
        Inventory.create_change_event(scope, %{
          kind: "discovered",
          resource_id: resource.id,
          source_id: source_id,
          observation_id: observation.id,
          new_value: %{"resource_id" => resource.id},
          occurred_at: observation.observed_at
        })
    end

    if freshness_advanced? do
      {:ok, _condition} =
        Inventory.put_resource_condition(scope, resource.id, %{
          type: "InventoryCurrent",
          status: "true",
          reason: "ObservationReconciled",
          message: "Inventory is current as of the latest reconciled observation",
          observed_generation: resource.generation,
          last_transition_at: condition_transition_now(scope, resource.id),
          details: %{
            "observation_id" => observation.id,
            "observed_at" => observation.observed_at
          }
        })
    end

    {:ok, result} =
      Inventory.create_observation_reconciliation(scope, observation.id, %{
        status: "succeeded",
        attempt: attempt,
        matched_resource_id: resource.id,
        metadata: %{"match" => match, "freshness_advanced" => freshness_advanced?},
        started_at: started_at,
        completed_at: completed_at
      })

    result
  end

  defp record_ambiguous(scope, observation, attempt, started_at, candidates) do
    {:ok, result} =
      Inventory.create_observation_reconciliation(scope, observation.id, %{
        status: "failed",
        attempt: attempt,
        errors: %{"identity" => "ambiguous", "candidate_resource_ids" => candidates},
        started_at: started_at,
        completed_at: Renga.Time.utc_now_ms()
      })

    result
  end

  defp next_attempt(scope, observation_id) do
    scope
    |> Inventory.list_observation_reconciliations(observation_id)
    |> List.last()
    |> case do
      nil -> 1
      result -> result.attempt + 1
    end
  end

  defp current_observation?(scope, resource_id, observation) do
    latest_observation =
      ObservationReconciliation
      |> join(:inner, [result], observation in Observation,
        on: observation.id == result.observation_id
      )
      |> where([result], result.organization_id == ^scope.organization_id)
      |> where([result], result.matched_resource_id == ^resource_id)
      |> where([result], result.status == "succeeded")
      |> order_by([_result, observation], desc: observation.observed_at, desc: observation.id)
      |> select([_result, observation], {observation.observed_at, observation.id})
      |> limit(1)
      |> Repo.one()

    case latest_observation do
      nil ->
        true

      {latest_observed_at, latest_id} ->
        {DateTime.to_unix(observation.observed_at, :microsecond), observation.id} >=
          {DateTime.to_unix(latest_observed_at, :microsecond), latest_id}
    end
  end

  defp condition_transition_now(scope, resource_id) do
    now = Renga.Time.utc_now_ms()

    case Enum.find(
           Inventory.list_resource_conditions(scope, resource_id),
           &(&1.type == "InventoryCurrent")
         ) do
      %{last_transition_at: previous} ->
        if DateTime.compare(now, previous) == :gt,
          do: now,
          else: DateTime.add(previous, 1, :millisecond)

      nil ->
        now
    end
  end

  defp observation_identifiers(payload) do
    resource = resource_payload(payload)

    {identity_interface_macs, non_identity_interface_macs} =
      resource
      |> Map.get("interfaces", [])
      |> Enum.reject(&(&1["status"] == "not_present"))
      |> Enum.reduce({[], MapSet.new()}, &classify_interface_mac/2)

    identity_mac_values = MapSet.new(identity_interface_macs, & &1.normalized_value)
    excluded_mac_values = MapSet.difference(non_identity_interface_macs, identity_mac_values)

    identifiers =
      resource
      |> Map.get("identifiers", %{})
      |> Enum.flat_map(fn {kind, values} ->
        Enum.map(List.wrap(values), &identifier(kind, &1))
      end)
      |> Enum.reject(
        &(&1.kind == "mac_address" and
            MapSet.member?(excluded_mac_values, &1.normalized_value))
      )

    Enum.uniq_by(identifiers ++ identity_interface_macs, &{&1.kind, &1.normalized_value})
  end

  defp classify_interface_mac(interface, {identity_macs, non_identity_macs}) do
    case Map.get(interface, "mac_address") do
      nil ->
        {identity_macs, non_identity_macs}

      mac_address ->
        mac_identifier = identifier("mac_address", mac_address)

        if Map.get(interface, "kind", "ethernet") in @identity_interface_kinds do
          {[mac_identifier | identity_macs], non_identity_macs}
        else
          {identity_macs, MapSet.put(non_identity_macs, mac_identifier.normalized_value)}
        end
    end
  end

  defp identifier(kind, value) do
    %{
      kind: kind,
      value: String.trim(value),
      normalized_value: ResourceIdentifier.normalize_value(kind, value)
    }
  end

  defp resource_payload(%{"resources" => [resource]}), do: resource

  defp resource_name(scope, observation, identifiers, kind) do
    base_name =
      Enum.find_value(@weak_identifier_kinds, fn identifier_kind ->
        Enum.find_value(identifiers, &if(&1.kind == identifier_kind, do: &1.normalized_value))
      end) || domain_name(observation) || kind

    if Repo.exists?(
         from resource in Resource,
           where:
             resource.organization_id == ^scope.organization_id and resource.kind == ^kind and
               resource.name == ^base_name
       ) do
      suffix =
        :crypto.hash(:sha256, observation.id)
        |> Base.encode16(case: :lower)
        |> String.slice(0, 12)

      "#{String.slice(base_name, 0, 242)}-#{suffix}"
    else
      String.slice(base_name, 0, 255)
    end
  end

  # A hypervisor knows a VM by its domain name long before any guest agent
  # reports a hostname.
  defp domain_name(observation) do
    case resource_payload(observation.payload) do
      %{"domain" => %{"name" => name}} when is_binary(name) and name != "" -> name
      _resource -> nil
    end
  end

  defp display_name(identifiers) do
    Enum.find_value(@weak_identifier_kinds, fn kind ->
      Enum.find_value(identifiers, &if(&1.kind == kind, do: &1.value))
    end)
  end

  defp confidence(kind) when kind in @weak_identifier_kinds, do: 60
  defp confidence(_kind), do: 100
end
