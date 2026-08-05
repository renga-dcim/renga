defmodule Renga.Inventory.Reconciler do
  @moduledoc """
  Reconciles immutable host observations into source-neutral inventory.

  Stable identifiers decide identity before names. Hostname and FQDN are only
  eligible when an observation has no strong identifier, which prevents a
  recycled name from merging two different machines.
  """

  import Ecto.Query, warn: false

  alias Renga.Accounts.Scope
  alias Renga.Inventory
  alias Renga.Inventory.Host
  alias Renga.Inventory.Interface
  alias Renga.Inventory.Observation
  alias Renga.Inventory.ObservationReconciliation
  alias Renga.Inventory.Reconciler.Projections
  alias Renga.Inventory.Resource
  alias Renga.Inventory.ResourceIdentifier
  alias Renga.Repo

  @strong_identifier_kinds ~w(serial_number dmi_uuid machine_id)
  @weak_identifier_kinds ~w(hostname fqdn)

  @doc """
  Reconciles one scoped observation and records its immutable processing result.
  """
  def reconcile(%Scope{} = scope, %Observation{} = observation) do
    do_reconcile(scope, observation)
  rescue
    exception -> record_unexpected_failure(scope, observation, exception)
  end

  defp do_reconcile(scope, observation) do
    source = Inventory.get_source!(scope, observation.source_id)
    identifiers = observation_identifiers(observation.payload)
    started_at = Renga.Time.utc_now_ms()

    Repo.transaction(fn ->
      lock_organization!(scope.organization_id)
      attempt = next_attempt(scope, observation.id)

      case match_resource(scope, identifiers) do
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
    end)
    |> case do
      {:ok, result} -> result
      {:error, reason} -> {:error, reason}
    end
  end

  defp record_unexpected_failure(scope, observation, exception) do
    now = Renga.Time.utc_now_ms()

    attrs = %{
      status: "failed",
      errors: %{"processing" => "projection_failed"},
      metadata: %{"exception" => exception.__struct__ |> Module.split() |> Enum.join(".")},
      started_at: now,
      completed_at: now
    }

    record_serialized_failure(scope, observation, attrs)
  end

  defp record_serialized_failure(scope, observation, attrs, retries \\ 1) do
    Repo.transaction(fn ->
      lock_organization!(scope.organization_id)

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
          record_serialized_failure(scope, observation, attrs, retries - 1)
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
    freshness_advanced? = current_observation?(scope, resource.id, observation)

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

    {:ok, resource, discovered?}
  end

  defp match_resource(scope, identifiers) do
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
      current_mac_rows =
        Resource
        |> join(:inner, [resource], interface in Interface,
          on: interface.resource_id == resource.id
        )
        |> where([resource], resource.organization_id == ^scope.organization_id)
        |> where([_resource, interface], interface.status != "not_present")
        |> where([_resource, interface], not is_nil(interface.mac_address))
        |> join(:inner, [resource, _interface], candidate in Interface,
          on:
            candidate.resource_id == resource.id and candidate.status != "not_present" and
              fragment("?::text", candidate.mac_address) in ^MapSet.to_list(observed_macs)
        )
        |> select(
          [resource, interface, _candidate],
          {resource, fragment("?::text", interface.mac_address)}
        )
        |> distinct(true)
        |> Repo.all()

      candidates =
        current_mac_rows
        |> Enum.group_by(fn {resource, _mac} -> resource.id end)
        |> Enum.flat_map(fn {_resource_id, rows} ->
          [{resource, _mac} | _rest] = rows
          current_macs = MapSet.new(rows, &elem(&1, 1))
          if MapSet.equal?(current_macs, observed_macs), do: [resource], else: []
        end)

      case candidates do
        [] -> :none
        [resource] -> {:ok, resource, %{"strategy" => "mac_address_set"}}
        resources -> {:error, Enum.map(resources, & &1.id)}
      end
    end
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
    |> where([_resource, host], field(host, ^field) in ^values)
    |> distinct(true)
    |> Repo.all()
  end

  defp ensure_resource(scope, observation, identifiers, nil) do
    name = resource_name(scope, observation, identifiers)

    {:ok, resource} =
      Inventory.create_resource(scope, %{
        kind: "server",
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
              Inventory.create_resource_identifier(scope, resource.id, %{
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

  defp lock_organization!(organization_id) do
    Repo.query!("SELECT pg_advisory_xact_lock(hashtextextended($1, 0))", [organization_id])
  end

  defp observation_identifiers(payload) do
    resource = resource_payload(payload)

    identifiers =
      resource
      |> Map.get("identifiers", %{})
      |> Enum.flat_map(fn {kind, values} ->
        Enum.map(List.wrap(values), &identifier(kind, &1))
      end)

    interface_macs =
      resource
      |> Map.get("interfaces", [])
      |> Enum.reject(&(&1["status"] == "not_present"))
      |> Enum.flat_map(fn interface ->
        case Map.get(interface, "mac_address") do
          nil -> []
          mac_address -> [identifier("mac_address", mac_address)]
        end
      end)

    Enum.uniq_by(identifiers ++ interface_macs, &{&1.kind, &1.normalized_value})
  end

  defp identifier(kind, value) do
    %{
      kind: kind,
      value: String.trim(value),
      normalized_value: ResourceIdentifier.normalize_value(kind, value)
    }
  end

  defp resource_payload(%{"resources" => [resource]}), do: resource

  defp resource_name(scope, observation, identifiers) do
    base_name =
      Enum.find_value(@weak_identifier_kinds, fn kind ->
        Enum.find_value(identifiers, &if(&1.kind == kind, do: &1.normalized_value))
      end) || "server"

    if Repo.exists?(
         from resource in Resource,
           where:
             resource.organization_id == ^scope.organization_id and resource.kind == "server" and
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

  defp display_name(identifiers) do
    Enum.find_value(@weak_identifier_kinds, fn kind ->
      Enum.find_value(identifiers, &if(&1.kind == kind, do: &1.value))
    end)
  end

  defp confidence(kind) when kind in @weak_identifier_kinds, do: 60
  defp confidence(_kind), do: 100
end
