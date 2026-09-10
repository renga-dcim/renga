defmodule Renga.Topology.NeighborReconciler do
  @moduledoc false

  import Ecto.Query, warn: false

  alias Renga.Accounts.Scope
  alias Renga.Inventory.Interface
  alias Renga.Inventory.Observation
  alias Renga.Inventory.Resource
  alias Renga.Inventory.ResourceIdentifier
  alias Renga.Inventory.Source
  alias Renga.Repo
  alias Renga.Topology.CurrentInterfaceAdjacency
  alias Renga.Topology.InterfaceNeighborEvidence
  alias Renga.Topology.InterfaceNeighborMatch
  alias Renga.Topology.TopologyFinding
  alias Renga.Topology.TopologySnapshotEvent
  alias Renga.Types.MacAddress

  @finding_kinds ~w(ambiguous_remote_identity asymmetric_neighbor conflicting_neighbors expired_adjacency)

  def reconcile(
        %Scope{organization_id: organization_id},
        %Source{} = source,
        %Observation{} = observation,
        resource_id,
        reported_interfaces,
        current_snapshot?
      ) do
    source = scoped_get!(Source, organization_id, source.id)
    scoped_get!(Resource, organization_id, resource_id)

    observation =
      Observation
      |> where([item], item.organization_id == ^organization_id)
      |> where([item], item.source_id == ^source.id and item.id == ^observation.id)
      |> Repo.one!()

    interfaces =
      Interface
      |> where([interface], interface.organization_id == ^organization_id)
      |> where([interface], interface.resource_id == ^resource_id)
      |> Repo.all()
      |> Map.new(&{&1.name, &1})

    evidence =
      Enum.flat_map(reported_interfaces, fn reported ->
        put_reported_neighbors(
          organization_id,
          source,
          observation,
          interfaces,
          reported,
          current_snapshot?
        )
      end)

    complete_snapshot? = complete_snapshot?(source, observation)
    maybe_record_snapshot(organization_id, source, observation, resource_id, complete_snapshot?)

    maybe_stale_omitted(
      organization_id,
      source,
      observation,
      resource_id,
      evidence,
      complete_snapshot?
    )

    refresh_evidence_staleness(organization_id, resource_id, observation.observed_at)
    stale_expired(organization_id, observation.observed_at)
    reconcile_active_matches(organization_id)
    adjacencies = rebuild_adjacencies(organization_id, observation.observed_at)
    reconcile_findings(organization_id, observation.observed_at, adjacencies)
    evidence
  end

  def expire(%Scope{organization_id: organization_id}, as_of) do
    stale_expired(organization_id, as_of)
    reconcile_active_matches(organization_id)
    adjacencies = rebuild_adjacencies(organization_id, as_of)
    reconcile_findings(organization_id, as_of, adjacencies)
    adjacencies
  end

  defp put_reported_neighbors(
         organization_id,
         source,
         observation,
         interfaces,
         reported,
         current_snapshot?
       ) do
    name = reported |> Map.fetch!("name") |> String.trim()

    case Map.fetch(interfaces, name) do
      {:ok, interface} ->
        neighbors = Map.get(reported, "neighbors", [])

        maybe_stale_replaced(
          organization_id,
          source,
          observation,
          interface,
          neighbors,
          current_snapshot?
        )

        Enum.map(neighbors, fn attrs ->
          put_evidence(organization_id, source, observation, interface, attrs)
        end)

      :error ->
        []
    end
  end

  defp put_evidence(organization_id, source, observation, interface, attrs) do
    existing =
      Repo.get_by(InterfaceNeighborEvidence,
        organization_id: organization_id,
        observation_id: observation.id,
        local_interface_id: interface.id,
        protocol: attrs["protocol"],
        remote_chassis_id: String.trim(attrs["remote_chassis_id"]),
        remote_port_id: String.trim(attrs["remote_port_id"])
      )

    existing ||
      %InterfaceNeighborEvidence{
        organization_id: organization_id,
        local_interface_id: interface.id,
        source_id: source.id,
        observation_id: observation.id
      }
      |> InterfaceNeighborEvidence.changeset(%{
        protocol: attrs["protocol"],
        remote_chassis_id: String.trim(attrs["remote_chassis_id"]),
        remote_chassis_id_kind: attrs["remote_chassis_id_kind"],
        remote_system_name: trim_optional(attrs["remote_system_name"]),
        remote_port_id: String.trim(attrs["remote_port_id"]),
        remote_port_id_kind: attrs["remote_port_id_kind"],
        remote_port_description: trim_optional(attrs["remote_port_description"]),
        ttl_seconds: attrs["ttl_seconds"],
        observed_at: observation.observed_at,
        expires_at: DateTime.add(observation.observed_at, attrs["ttl_seconds"], :second),
        metadata: Map.get(attrs, "metadata", %{})
      })
      |> insert_or_rollback()
  end

  defp maybe_stale_replaced(
         _organization_id,
         _source,
         _observation,
         _interface,
         _neighbors,
         false
       ),
       do: :ok

  defp maybe_stale_replaced(organization_id, source, observation, interface, neighbors, true) do
    protocols = neighbors |> Enum.map(& &1["protocol"]) |> Enum.uniq()

    if protocols != [] do
      InterfaceNeighborEvidence
      |> where([item], item.organization_id == ^organization_id)
      |> where([item], item.source_id == ^source.id and item.local_interface_id == ^interface.id)
      |> where([item], item.protocol in ^protocols and is_nil(item.stale_at))
      |> where(
        [item],
        item.observed_at < ^observation.observed_at or
          (item.observed_at == ^observation.observed_at and item.observation_id < ^observation.id)
      )
      |> Repo.update_all(set: [stale_at: observation.observed_at, stale_reason: "superseded"])
    end
  end

  defp maybe_record_snapshot(_organization_id, _source, _observation, _resource_id, false),
    do: :ok

  defp maybe_record_snapshot(organization_id, source, observation, resource_id, true) do
    existing =
      Repo.get_by(TopologySnapshotEvent,
        organization_id: organization_id,
        source_id: source.id,
        observation_id: observation.id,
        resource_id: resource_id,
        section: "interface_neighbors"
      )

    unless existing do
      %TopologySnapshotEvent{
        organization_id: organization_id,
        source_id: source.id,
        observation_id: observation.id,
        resource_id: resource_id
      }
      |> TopologySnapshotEvent.changeset(%{
        section: "interface_neighbors",
        observed_at: observation.observed_at
      })
      |> insert_or_rollback()
    end
  end

  defp maybe_stale_omitted(
         _organization_id,
         _source,
         _observation,
         _resource_id,
         _evidence,
         false
       ),
       do: :ok

  defp maybe_stale_omitted(organization_id, source, observation, resource_id, evidence, true) do
    observed_ids = Enum.map(evidence, & &1.id)

    InterfaceNeighborEvidence
    |> join(:inner, [item], interface in Interface, on: interface.id == item.local_interface_id)
    |> where([item, interface], item.organization_id == ^organization_id)
    |> where([item, _interface], item.source_id == ^source.id and is_nil(item.stale_at))
    |> where([_item, interface], interface.resource_id == ^resource_id)
    |> where(
      [item, _interface],
      item.observed_at < ^observation.observed_at or
        (item.observed_at == ^observation.observed_at and item.observation_id < ^observation.id)
    )
    |> maybe_exclude_ids(observed_ids)
    |> Repo.update_all(set: [stale_at: observation.observed_at, stale_reason: "withdrawn"])
  end

  defp maybe_exclude_ids(query, []), do: query
  defp maybe_exclude_ids(query, ids), do: where(query, [item, _interface], item.id not in ^ids)

  defp refresh_evidence_staleness(organization_id, resource_id, as_of) do
    boundaries = latest_boundaries(organization_id, resource_id)

    evidence =
      InterfaceNeighborEvidence
      |> join(:inner, [item], interface in Interface, on: interface.id == item.local_interface_id)
      |> where([item, interface], item.organization_id == ^organization_id)
      |> where([_item, interface], interface.resource_id == ^resource_id)
      |> where([item, _interface], is_nil(item.stale_at))
      |> select([item, _interface], item)
      |> Repo.all()

    evidence
    |> Enum.group_by(&{&1.source_id, &1.local_interface_id, &1.protocol})
    |> Enum.each(fn {{source_id, _, _}, items} ->
      latest = Enum.max_by(items, &evidence_order/1)
      boundary = Map.get(boundaries, source_id)

      Enum.each(items, fn item ->
        {stale_at, reason} = evidence_staleness(item, latest, boundary, as_of)
        maybe_stale(item, stale_at, reason)
      end)
    end)
  end

  defp evidence_staleness(item, latest, boundary, as_of) do
    cond do
      DateTime.compare(item.expires_at, as_of) != :gt ->
        {item.expires_at, "expired"}

      evidence_order(item) < evidence_order(latest) ->
        {latest.observed_at, "superseded"}

      boundary && evidence_order(item) < evidence_order(boundary) ->
        {boundary.observed_at, "withdrawn"}

      true ->
        {nil, nil}
    end
  end

  defp stale_expired(organization_id, as_of) do
    InterfaceNeighborEvidence
    |> where([item], item.organization_id == ^organization_id)
    |> where([item], is_nil(item.stale_at) and item.expires_at <= ^as_of)
    |> Repo.all()
    |> Enum.each(&maybe_stale(&1, &1.expires_at, "expired"))
  end

  defp maybe_stale(_item, nil, nil), do: :ok

  defp maybe_stale(%{stale_at: nil} = item, stale_at, reason) do
    item
    |> Ecto.Changeset.change(stale_at: stale_at, stale_reason: reason)
    |> update_or_rollback()
  end

  defp maybe_stale(_item, _stale_at, _reason), do: :ok

  defp latest_boundaries(organization_id, resource_id) do
    TopologySnapshotEvent
    |> where([event], event.organization_id == ^organization_id)
    |> where(
      [event],
      event.resource_id == ^resource_id and event.section == "interface_neighbors"
    )
    |> Repo.all()
    |> Enum.group_by(& &1.source_id)
    |> Map.new(fn {source_id, events} -> {source_id, Enum.max_by(events, &evidence_order/1)} end)
  end

  defp reconcile_active_matches(organization_id) do
    InterfaceNeighborEvidence
    |> where([item], item.organization_id == ^organization_id and is_nil(item.stale_at))
    |> Repo.all()
    |> Enum.each(fn evidence ->
      attrs = match_remote_interface(organization_id, evidence)

      (Repo.get_by(InterfaceNeighborMatch,
         organization_id: organization_id,
         interface_neighbor_evidence_id: evidence.id
       ) ||
         %InterfaceNeighborMatch{
           organization_id: organization_id,
           interface_neighbor_evidence_id: evidence.id
         })
      |> InterfaceNeighborMatch.changeset(attrs)
      |> Repo.insert_or_update()
      |> unwrap_or_rollback()
    end)
  end

  defp match_remote_interface(organization_id, evidence) do
    {resource_ids, stable_chassis?} = matching_resources(organization_id, evidence)
    {interfaces, stable_port?} = matching_interfaces(organization_id, resource_ids, evidence)
    interfaces = Enum.reject(interfaces, &(&1.id == evidence.local_interface_id))

    case interfaces do
      [interface] ->
        %{
          status: "matched",
          strategy:
            if(stable_chassis? and stable_port?, do: "stable_identifiers", else: "name_fallback"),
          candidate_count: 1,
          remote_interface_id: interface.id
        }

      [] ->
        %{status: "unresolved", strategy: nil, candidate_count: 0, remote_interface_id: nil}

      candidates ->
        %{
          status: "ambiguous",
          strategy: nil,
          candidate_count: length(candidates),
          remote_interface_id: nil
        }
    end
  end

  defp matching_resources(organization_id, evidence) do
    stable_ids =
      if evidence.remote_chassis_id_kind == "name",
        do: [],
        else: stable_resource_ids(organization_id, evidence)

    if stable_ids == [] do
      {named_resource_ids(organization_id, evidence), false}
    else
      {stable_ids, true}
    end
  end

  defp stable_resource_ids(organization_id, evidence) do
    values = normalized_identifier_values(evidence.remote_chassis_id)
    identifier_kinds = chassis_identifier_kinds(evidence.remote_chassis_id_kind)

    identifier_ids =
      ResourceIdentifier
      |> where([identifier], identifier.organization_id == ^organization_id)
      |> where([identifier], identifier.kind in ^identifier_kinds)
      |> where([identifier], identifier.normalized_value in ^values)
      |> select([identifier], identifier.resource_id)
      |> Repo.all()

    interface_ids =
      case {evidence.remote_chassis_id_kind, MacAddress.cast(evidence.remote_chassis_id)} do
        {kind, {:ok, mac}} when kind in [nil, "local", "mac_address"] ->
          Interface
          |> where([interface], interface.organization_id == ^organization_id)
          |> where([interface], interface.mac_address == ^mac)
          |> select([interface], interface.resource_id)
          |> Repo.all()

        _not_a_mac_chassis_id ->
          []
      end

    Enum.uniq(identifier_ids ++ interface_ids)
  end

  defp chassis_identifier_kinds("mac_address"), do: ["mac_address"]
  defp chassis_identifier_kinds("network_address"), do: ["bmc_address"]

  defp chassis_identifier_kinds(_local_or_unspecified) do
    ~w(serial_number machine_id dmi_uuid mac_address provider_instance_id bmc_address external_id)
  end

  defp normalized_identifier_values(value) do
    [
      String.trim(value),
      value |> String.trim() |> String.downcase(),
      ResourceIdentifier.normalize_value("mac_address", value)
    ]
    |> Enum.uniq()
  end

  defp named_resource_ids(organization_id, evidence) do
    names =
      [evidence.remote_system_name, evidence.remote_chassis_id]
      |> Enum.reject(&is_nil/1)
      |> Enum.map(&(String.trim(&1) |> String.downcase()))
      |> Enum.uniq()

    resource_ids =
      Resource
      |> where([resource], resource.organization_id == ^organization_id)
      |> where(
        [resource],
        fragment("lower(?)", resource.name) in ^names or
          fragment("lower(?)", resource.display_name) in ^names
      )
      |> select([resource], resource.id)
      |> Repo.all()

    identifier_ids =
      ResourceIdentifier
      |> where([identifier], identifier.organization_id == ^organization_id)
      |> where([identifier], identifier.kind in ["hostname", "fqdn"])
      |> where([identifier], identifier.normalized_value in ^names)
      |> select([identifier], identifier.resource_id)
      |> Repo.all()

    Enum.uniq(resource_ids ++ identifier_ids)
  end

  defp matching_interfaces(_organization_id, [], _evidence), do: {[], false}

  defp matching_interfaces(organization_id, resource_ids, evidence) do
    stable =
      if evidence.remote_port_id_kind == "name",
        do: [],
        else: stable_port_interfaces(organization_id, resource_ids, evidence)

    if stable == [] do
      {named_port_interfaces(organization_id, resource_ids, evidence), false}
    else
      {stable, true}
    end
  end

  defp stable_port_interfaces(organization_id, resource_ids, evidence) do
    case MacAddress.cast(evidence.remote_port_id) do
      {:ok, mac} ->
        Interface
        |> where([interface], interface.organization_id == ^organization_id)
        |> where(
          [interface],
          interface.resource_id in ^resource_ids and interface.mac_address == ^mac
        )
        |> Repo.all()

      :error ->
        []
    end
  end

  defp named_port_interfaces(organization_id, resource_ids, evidence) do
    names =
      [evidence.remote_port_id, evidence.remote_port_description]
      |> Enum.reject(&is_nil/1)
      |> Enum.map(&String.trim/1)
      |> Enum.uniq()

    Interface
    |> where([interface], interface.organization_id == ^organization_id)
    |> where([interface], interface.resource_id in ^resource_ids and interface.name in ^names)
    |> Repo.all()
  end

  defp rebuild_adjacencies(organization_id, _as_of) do
    evidence = active_matched_evidence(organization_id)
    candidates = adjacency_candidates(evidence)
    selected = select_non_conflicting_adjacencies(candidates)

    CurrentInterfaceAdjacency
    |> where([adjacency], adjacency.organization_id == ^organization_id)
    |> Repo.delete_all()

    Enum.map(selected, fn candidate ->
      %CurrentInterfaceAdjacency{
        organization_id: organization_id,
        interface_a_id: candidate.interface_a_id,
        interface_b_id: candidate.interface_b_id,
        primary_evidence_id: candidate.primary.id
      }
      |> CurrentInterfaceAdjacency.changeset(%{
        confidence: candidate.confidence,
        last_observed_at: candidate.primary.observed_at,
        metadata: %{"protocols" => candidate.protocols}
      })
      |> insert_or_rollback()
    end)
  end

  defp active_matched_evidence(organization_id) do
    InterfaceNeighborEvidence
    |> join(:inner, [evidence], match in InterfaceNeighborMatch,
      on: match.interface_neighbor_evidence_id == evidence.id
    )
    |> where([evidence, match], evidence.organization_id == ^organization_id)
    |> where([evidence, match], is_nil(evidence.stale_at) and match.status == "matched")
    |> select([evidence, match], {evidence, match.remote_interface_id})
    |> Repo.all()
  end

  defp adjacency_candidates(evidence) do
    directed =
      MapSet.new(evidence, fn {item, remote_id} -> {item.local_interface_id, remote_id} end)

    evidence
    |> Enum.group_by(fn {item, remote_id} ->
      canonical_pair(item.local_interface_id, remote_id)
    end)
    |> Enum.map(fn {{interface_a_id, interface_b_id}, items} ->
      primary = items |> Enum.map(&elem(&1, 0)) |> Enum.max_by(&evidence_order/1)

      reciprocal? =
        MapSet.member?(directed, {interface_a_id, interface_b_id}) and
          MapSet.member?(directed, {interface_b_id, interface_a_id})

      %{
        interface_a_id: interface_a_id,
        interface_b_id: interface_b_id,
        primary: primary,
        confidence: if(reciprocal?, do: "reciprocal", else: "reported"),
        protocols:
          items |> Enum.map(fn {item, _} -> item.protocol end) |> Enum.uniq() |> Enum.sort()
      }
    end)
  end

  defp select_non_conflicting_adjacencies(candidates) do
    candidates
    |> Enum.sort_by(fn candidate ->
      confidence_rank = if candidate.confidence == "reciprocal", do: 0, else: 1

      {confidence_rank, -DateTime.to_unix(candidate.primary.observed_at, :microsecond),
       candidate.interface_a_id, candidate.interface_b_id}
    end)
    |> Enum.reduce({[], MapSet.new()}, fn candidate, {selected, used} ->
      if MapSet.member?(used, candidate.interface_a_id) or
           MapSet.member?(used, candidate.interface_b_id) do
        {selected, used}
      else
        {[candidate | selected],
         used |> MapSet.put(candidate.interface_a_id) |> MapSet.put(candidate.interface_b_id)}
      end
    end)
    |> elem(0)
    |> Enum.reverse()
  end

  defp reconcile_findings(organization_id, observed_at, adjacencies) do
    evidence = latest_neighbor_evidence(organization_id)
    matches = neighbor_matches(organization_id, evidence)

    findings =
      ambiguous_findings(evidence, matches, observed_at) ++
        conflicting_findings(evidence, matches, observed_at) ++
        asymmetric_findings(adjacencies, observed_at) ++
        expired_findings(evidence, observed_at)

    grouped = Enum.group_by(findings, & &1.interface_id)

    Interface
    |> where([interface], interface.organization_id == ^organization_id)
    |> select([interface], interface.id)
    |> Repo.all()
    |> Enum.each(fn interface_id ->
      desired = Map.get(grouped, interface_id, [])
      keys = MapSet.new(desired, &{&1.kind, &1.resolution_key})
      Enum.each(desired, &put_finding(organization_id, interface_id, &1))

      TopologyFinding
      |> where([finding], finding.organization_id == ^organization_id)
      |> where([finding], finding.interface_id == ^interface_id)
      |> where([finding], finding.status == "open" and finding.kind in ^@finding_kinds)
      |> Repo.all()
      |> Enum.reject(&MapSet.member?(keys, {&1.kind, &1.resolution_key}))
      |> Enum.each(&resolve_finding(&1, observed_at))
    end)
  end

  defp latest_neighbor_evidence(organization_id) do
    InterfaceNeighborEvidence
    |> where([item], item.organization_id == ^organization_id)
    |> Repo.all()
    |> Enum.group_by(&{&1.source_id, &1.local_interface_id, &1.protocol})
    |> Enum.flat_map(fn {_key, items} ->
      latest_order = items |> Enum.max_by(&evidence_order/1) |> evidence_order()
      Enum.filter(items, &(evidence_order(&1) == latest_order))
    end)
  end

  defp neighbor_matches(organization_id, evidence) do
    ids = Enum.map(evidence, & &1.id)

    if ids == [] do
      %{}
    else
      InterfaceNeighborMatch
      |> where([match], match.organization_id == ^organization_id)
      |> where([match], match.interface_neighbor_evidence_id in ^ids)
      |> Repo.all()
      |> Map.new(&{&1.interface_neighbor_evidence_id, &1})
    end
  end

  defp ambiguous_findings(evidence, matches, observed_at) do
    evidence
    |> Enum.filter(
      &((is_nil(&1.stale_at) and matches[&1.id]) &&
          matches[&1.id].status in ~w(unresolved ambiguous))
    )
    |> Enum.map(fn item ->
      match = matches[item.id]

      neighbor_finding(
        item.local_interface_id,
        "ambiguous_remote_identity",
        item.id,
        "Neighbor endpoint could not be matched uniquely",
        %{
          "evidence_id" => item.id,
          "match_status" => match.status,
          "candidate_count" => match.candidate_count,
          "remote_chassis_id" => item.remote_chassis_id,
          "remote_port_id" => item.remote_port_id
        },
        observed_at
      )
    end)
  end

  defp conflicting_findings(evidence, matches, observed_at) do
    pairs =
      evidence
      |> Enum.filter(
        &((matches[&1.id] && matches[&1.id].status == "matched") and is_nil(&1.stale_at))
      )
      |> Enum.map(fn item ->
        canonical_pair(item.local_interface_id, matches[item.id].remote_interface_id)
      end)
      |> Enum.uniq()

    pairs
    |> Enum.flat_map(fn {interface_a_id, interface_b_id} = pair ->
      [{interface_a_id, pair}, {interface_b_id, pair}]
    end)
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
    |> Enum.filter(fn {_interface_id, interface_pairs} -> length(interface_pairs) > 1 end)
    |> Enum.map(fn {interface_id, interface_pairs} ->
      remote_ids = Enum.map(interface_pairs, &other_endpoint(&1, interface_id))

      neighbor_finding(
        interface_id,
        "conflicting_neighbors",
        "active",
        "Sources report conflicting neighbors",
        %{"remote_interface_ids" => Enum.sort(remote_ids)},
        observed_at
      )
    end)
  end

  defp other_endpoint({interface_id, remote_interface_id}, interface_id),
    do: remote_interface_id

  defp other_endpoint({remote_interface_id, interface_id}, interface_id),
    do: remote_interface_id

  defp asymmetric_findings(adjacencies, observed_at) do
    adjacencies
    |> Enum.filter(&(&1.confidence == "reported"))
    |> Enum.flat_map(fn adjacency ->
      details = %{
        "interface_a_id" => adjacency.interface_a_id,
        "interface_b_id" => adjacency.interface_b_id
      }

      [
        neighbor_finding(
          adjacency.interface_a_id,
          "asymmetric_neighbor",
          adjacency_key(adjacency),
          "Neighbor adjacency has not been observed reciprocally",
          details,
          observed_at
        ),
        neighbor_finding(
          adjacency.interface_b_id,
          "asymmetric_neighbor",
          adjacency_key(adjacency),
          "Neighbor adjacency has not been observed reciprocally",
          details,
          observed_at
        )
      ]
    end)
  end

  defp expired_findings(evidence, observed_at) do
    evidence
    |> Enum.filter(&(&1.stale_reason == "expired"))
    |> Enum.map(fn item ->
      neighbor_finding(
        item.local_interface_id,
        "expired_adjacency",
        item.id,
        "Latest neighbor evidence has expired",
        %{"evidence_id" => item.id},
        observed_at
      )
    end)
  end

  defp neighbor_finding(interface_id, kind, key, message, details, observed_at) do
    %{
      interface_id: interface_id,
      kind: kind,
      resolution_key: to_string(key),
      message: message,
      details: details,
      last_observed_at: observed_at
    }
  end

  defp put_finding(organization_id, interface_id, attrs) do
    existing =
      Repo.get_by(TopologyFinding,
        organization_id: organization_id,
        interface_id: interface_id,
        kind: attrs.kind,
        resolution_key: attrs.resolution_key,
        status: "open"
      )

    attrs = Map.drop(attrs, [:interface_id])

    attrs =
      if existing,
        do: Map.update!(attrs, :last_observed_at, &max_datetime(&1, existing.last_observed_at)),
        else: attrs

    (existing || %TopologyFinding{organization_id: organization_id, interface_id: interface_id})
    |> TopologyFinding.changeset(Map.merge(attrs, %{status: "open", resolved_at: nil}))
    |> Repo.insert_or_update()
    |> unwrap_or_rollback()
  end

  defp resolve_finding(finding, observed_at) do
    resolved_at = max_datetime(observed_at, finding.last_observed_at)

    finding
    |> TopologyFinding.changeset(%{status: "resolved", resolved_at: resolved_at})
    |> update_or_rollback()
  end

  defp complete_snapshot?(source, observation) do
    source.metadata["interface_neighbor_snapshot_policy"] == "complete" and
      match?(%{"section_completeness" => %{"interface_neighbors" => true}}, observation.payload)
  end

  defp canonical_pair(first, second),
    do: if(first < second, do: {first, second}, else: {second, first})

  defp adjacency_key(adjacency),
    do: "#{adjacency.interface_a_id}:#{adjacency.interface_b_id}"

  defp evidence_order(item),
    do: {DateTime.to_unix(item.observed_at, :microsecond), item.observation_id}

  defp max_datetime(first, second),
    do: if(DateTime.compare(first, second) == :lt, do: second, else: first)

  defp trim_optional(nil), do: nil
  defp trim_optional(value), do: String.trim(value)

  defp scoped_get!(schema, organization_id, id) do
    schema |> where([item], item.organization_id == ^organization_id) |> Repo.get!(id)
  end

  defp insert_or_rollback(changeset), do: changeset |> Repo.insert() |> unwrap_or_rollback()
  defp update_or_rollback(changeset), do: changeset |> Repo.update() |> unwrap_or_rollback()

  defp unwrap_or_rollback({:ok, result}), do: result
  defp unwrap_or_rollback({:error, reason}), do: Repo.rollback(reason)
end
