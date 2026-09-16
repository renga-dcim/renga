defmodule Renga.Topology.NeighborReconciler do
  @moduledoc false

  import Ecto.Query, warn: false

  alias Renga.Accounts.Scope
  alias Renga.Inventory.Host
  alias Renga.Inventory.Interface
  alias Renga.Inventory.Observation
  alias Renga.Inventory.Resource
  alias Renga.Inventory.ResourceIdentifier
  alias Renga.Inventory.Source
  alias Renga.Repo
  alias Renga.Topology.CurrentInterfaceAdjacency
  alias Renga.Topology.InterfaceNeighborEvidence
  alias Renga.Topology.InterfaceNeighborMatch
  alias Renga.Topology.NeighborIdentifier
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
        _current_snapshot?
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
          reported
        )
      end)

    complete_snapshot? = complete_snapshot?(source, observation)
    maybe_record_snapshot(organization_id, source, observation, resource_id, complete_snapshot?)

    as_of = Renga.Time.utc_now_ms()

    newly_expired_ids =
      refresh_evidence_staleness(organization_id, resource_id, as_of) ++
        stale_expired(organization_id, as_of)

    reconcile_active_matches(organization_id)
    adjacencies = rebuild_adjacencies(organization_id, observation.observed_at)
    reconcile_findings(organization_id, as_of, adjacencies, newly_expired_ids)
    evidence
  end

  def expire(%Scope{organization_id: organization_id}, as_of) do
    newly_expired_ids = stale_expired(organization_id, as_of)
    reconcile_active_matches(organization_id)
    adjacencies = rebuild_adjacencies(organization_id, as_of)
    reconcile_findings(organization_id, as_of, adjacencies, newly_expired_ids)
    adjacencies
  end

  def refresh(%Scope{organization_id: organization_id}, as_of) do
    newly_expired_ids = stale_expired(organization_id, as_of)
    reconcile_active_matches(organization_id)
    adjacencies = rebuild_adjacencies(organization_id, as_of)
    reconcile_findings(organization_id, as_of, adjacencies, newly_expired_ids)
    adjacencies
  end

  defp put_reported_neighbors(
         organization_id,
         source,
         observation,
         interfaces,
         reported
       ) do
    name = reported |> Map.fetch!("name") |> String.trim()

    case Map.fetch(interfaces, name) do
      {:ok, interface} ->
        neighbors = Map.get(reported, "neighbors", [])

        Enum.map(neighbors, fn attrs ->
          put_evidence(organization_id, source, observation, interface, attrs)
        end)

      :error ->
        []
    end
  end

  defp put_evidence(organization_id, source, observation, interface, attrs) do
    chassis_kind = attrs["remote_chassis_id_kind"]
    chassis_id = String.trim(attrs["remote_chassis_id"])
    port_kind = attrs["remote_port_id_kind"]
    port_id = String.trim(attrs["remote_port_id"])

    existing =
      InterfaceNeighborEvidence
      |> where(
        [evidence],
        evidence.organization_id == ^organization_id and
          evidence.observation_id == ^observation.id and
          evidence.local_interface_id == ^interface.id and
          evidence.protocol == ^attrs["protocol"] and
          evidence.remote_chassis_id_normalized ==
            ^NeighborIdentifier.normalize_chassis(chassis_kind, chassis_id) and
          evidence.remote_port_id_normalized ==
            ^NeighborIdentifier.normalize_port(port_kind, port_id)
      )
      |> where_nullable(:remote_chassis_id_kind, chassis_kind)
      |> where_nullable(:remote_port_id_kind, port_kind)
      |> Repo.one()

    existing ||
      %InterfaceNeighborEvidence{
        organization_id: organization_id,
        local_interface_id: interface.id,
        source_id: source.id,
        observation_id: observation.id
      }
      |> InterfaceNeighborEvidence.changeset(%{
        protocol: attrs["protocol"],
        remote_chassis_id: chassis_id,
        remote_chassis_id_kind: chassis_kind,
        remote_system_name: trim_optional(attrs["remote_system_name"]),
        remote_port_id: port_id,
        remote_port_id_kind: port_kind,
        remote_port_description: trim_optional(attrs["remote_port_description"]),
        ttl_seconds: attrs["ttl_seconds"],
        observed_at: observation.observed_at,
        expires_at: DateTime.add(observation.observed_at, attrs["ttl_seconds"], :second),
        metadata: Map.get(attrs, "metadata", %{})
      })
      |> insert_or_rollback()
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

  defp refresh_evidence_staleness(organization_id, resource_id, as_of) do
    active_evidence =
      InterfaceNeighborEvidence
      |> join(:inner, [item], interface in Interface, on: interface.id == item.local_interface_id)
      |> where([item, interface], item.organization_id == ^organization_id)
      |> where([item, interface], interface.resource_id == ^resource_id and is_nil(item.stale_at))
      |> select([item, _interface], item)
      |> Repo.all()

    boundaries =
      active_evidence
      |> Enum.map(& &1.source_id)
      |> Enum.uniq()
      |> Map.new(fn source_id ->
        {source_id, latest_boundary(organization_id, resource_id, source_id)}
      end)

    active_evidence
    |> Enum.map(fn item ->
      latest_item = latest_identity_evidence(organization_id, item)
      boundary = Map.get(boundaries, item.source_id)
      {stale_at, reason} = evidence_staleness(item, latest_item, boundary, as_of)
      maybe_stale(item, stale_at, reason)
    end)
    |> expired_ids()
  end

  defp latest_identity_evidence(organization_id, item) do
    InterfaceNeighborEvidence
    |> where(
      [candidate],
      candidate.organization_id == ^organization_id and
        candidate.source_id == ^item.source_id and
        candidate.local_interface_id == ^item.local_interface_id and
        candidate.protocol == ^item.protocol and
        candidate.remote_chassis_id_normalized == ^item.remote_chassis_id_normalized and
        candidate.remote_port_id_normalized == ^item.remote_port_id_normalized
    )
    |> where_nullable(:remote_chassis_id_kind, item.remote_chassis_id_kind)
    |> where_nullable(:remote_port_id_kind, item.remote_port_id_kind)
    |> order_by([candidate], desc: candidate.observed_at, desc: candidate.observation_id)
    |> limit(1)
    |> Repo.one!()
  end

  defp evidence_staleness(item, latest, boundary, as_of) do
    cond do
      evidence_order(item) < evidence_order(latest) ->
        {latest.observed_at, "superseded"}

      DateTime.compare(item.expires_at, as_of) != :gt ->
        {item.expires_at, "expired"}

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
    |> Enum.map(&maybe_stale(&1, &1.expires_at, "expired"))
    |> expired_ids()
  end

  defp maybe_stale(_item, nil, nil), do: :ok

  defp maybe_stale(%{stale_at: nil} = item, stale_at, reason) do
    updated =
      item
      |> Ecto.Changeset.change(stale_at: stale_at, stale_reason: reason)
      |> update_or_rollback()

    {:staled, updated}
  end

  defp maybe_stale(_item, _stale_at, _reason), do: :ok

  defp expired_ids(results) do
    for {:staled, %{id: id, stale_reason: "expired"}} <- results, do: id
  end

  defp latest_boundary(organization_id, resource_id, source_id) do
    TopologySnapshotEvent
    |> where([event], event.organization_id == ^organization_id)
    |> where(
      [event],
      event.resource_id == ^resource_id and event.source_id == ^source_id and
        event.section == "interface_neighbors"
    )
    |> order_by([event], desc: event.observed_at, desc: event.observation_id)
    |> limit(1)
    |> Repo.one()
  end

  defp reconcile_active_matches(organization_id) do
    ineligible_evidence_ids =
      InterfaceNeighborEvidence
      |> join(:inner, [item], interface in Interface, on: interface.id == item.local_interface_id)
      |> where(
        [item, interface],
        item.organization_id == ^organization_id and is_nil(item.stale_at) and
          interface.status == "not_present"
      )
      |> select([item, _interface], item.id)

    InterfaceNeighborMatch
    |> where(
      [match],
      match.organization_id == ^organization_id and
        match.interface_neighbor_evidence_id in subquery(ineligible_evidence_ids)
    )
    |> Repo.delete_all()

    evidence =
      InterfaceNeighborEvidence
      |> join(:inner, [item], interface in Interface, on: interface.id == item.local_interface_id)
      |> where(
        [item, interface],
        item.organization_id == ^organization_id and is_nil(item.stale_at) and
          interface.status != "not_present"
      )
      |> select([item, _interface], item)
      |> Repo.all()

    bmc_resources = bmc_resource_lookup(organization_id, evidence)

    evidence
    |> Enum.each(fn evidence ->
      attrs = match_remote_interface(organization_id, evidence, bmc_resources)

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

  defp match_remote_interface(organization_id, evidence, bmc_resources) do
    stable_resource_ids = stable_resource_ids(organization_id, evidence, bmc_resources)
    stable_ports = stable_port_interfaces(organization_id, :all, evidence)

    {interfaces, strategy} =
      case {stable_resource_ids, stable_ports} do
        {[], []} ->
          resource_ids = named_resource_ids(organization_id, evidence)
          {named_port_interfaces(organization_id, resource_ids, evidence), "name_fallback"}

        {[], stable_ports} ->
          {stable_ports, "stable_identifiers"}

        {stable_resource_ids, []} ->
          {named_port_interfaces(organization_id, stable_resource_ids, evidence), "name_fallback"}

        {stable_resource_ids, stable_ports} ->
          matching_stable_ports =
            Enum.filter(stable_ports, &(&1.resource_id in stable_resource_ids))

          {matching_stable_ports, "stable_identifiers"}
      end

    interfaces = Enum.reject(interfaces, &(&1.id == evidence.local_interface_id))

    case interfaces do
      [interface] ->
        %{
          status: "matched",
          strategy: strategy,
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

  defp stable_resource_ids(organization_id, evidence, bmc_resources) do
    identifier_kinds =
      cond do
        evidence.remote_chassis_id_kind in ["name", "mac_address"] ->
          []

        is_nil(evidence.remote_chassis_id_kind) and
            NeighborIdentifier.mac_address?(evidence.remote_chassis_id) ->
          []

        true ->
          chassis_identifier_kinds(evidence.remote_chassis_id_kind)
      end

    identifier_ids =
      matching_identifier_resource_ids(organization_id, identifier_kinds, evidence, bmc_resources)

    interface_ids =
      case {
        evidence.remote_chassis_id_kind,
        NeighborIdentifier.mac_address?(evidence.remote_chassis_id),
        MacAddress.cast(evidence.remote_chassis_id)
      } do
        {kind, true, {:ok, mac}} when kind in [nil, "mac_address"] ->
          Interface
          |> where([interface], interface.organization_id == ^organization_id)
          |> where(
            [interface],
            interface.status != "not_present" and interface.mac_address == ^mac
          )
          |> select([interface], interface.resource_id)
          |> Repo.all()

        _not_a_mac_chassis_id ->
          []
      end

    Enum.uniq(identifier_ids ++ interface_ids)
  end

  defp matching_identifier_resource_ids(_organization_id, [], _evidence, _bmc_resources), do: []

  defp matching_identifier_resource_ids(
         _organization_id,
         ["bmc_address"],
         %{
           remote_chassis_id_kind: "network_address",
           remote_chassis_id: value
         },
         bmc_resources
       ) do
    normalized = NeighborIdentifier.normalize_chassis("network_address", value)
    Map.get(bmc_resources, normalized, [])
  end

  defp matching_identifier_resource_ids(
         organization_id,
         identifier_kinds,
         evidence,
         _bmc_resources
       ) do
    identity_match =
      Enum.reduce(identifier_kinds, dynamic(false), fn kind, identity_match ->
        normalized_value = ResourceIdentifier.normalize_value(kind, evidence.remote_chassis_id)

        dynamic(
          [identifier],
          ^identity_match or
            (identifier.kind == ^kind and identifier.normalized_value == ^normalized_value)
        )
      end)

    ResourceIdentifier
    |> where([identifier], identifier.organization_id == ^organization_id)
    |> where(^identity_match)
    |> select([identifier], identifier.resource_id)
    |> Repo.all()
  end

  defp bmc_resource_lookup(organization_id, evidence) do
    if Enum.any?(evidence, &(&1.remote_chassis_id_kind == "network_address")) do
      ResourceIdentifier
      |> where(
        [identifier],
        identifier.organization_id == ^organization_id and identifier.kind == "bmc_address"
      )
      |> select([identifier], {identifier.resource_id, identifier.value})
      |> Repo.all()
      |> Enum.group_by(
        fn {_resource_id, value} ->
          NeighborIdentifier.normalize_chassis("network_address", value)
        end,
        &elem(&1, 0)
      )
    else
      %{}
    end
  end

  defp chassis_identifier_kinds("mac_address"), do: []
  defp chassis_identifier_kinds("network_address"), do: ["bmc_address"]

  defp chassis_identifier_kinds(_local_or_unspecified) do
    ~w(serial_number machine_id dmi_uuid provider_instance_id bmc_address external_id)
  end

  defp named_resource_ids(organization_id, evidence) do
    names =
      [
        evidence.remote_system_name,
        identifier_name_hint(evidence.remote_chassis_id_kind, evidence.remote_chassis_id)
      ]
      |> Enum.reject(&is_nil/1)
      |> Enum.map(&(String.trim(&1) |> String.downcase()))
      |> Enum.uniq()

    resource_ids =
      Resource
      |> join(:left, [resource], host in Host, on: host.resource_id == resource.id)
      |> where([resource, _host], resource.organization_id == ^organization_id)
      |> where(
        [resource, host],
        is_nil(host.id) and
          (fragment("lower(?)", resource.name) in ^names or
             fragment("lower(?)", resource.display_name) in ^names)
      )
      |> select([resource, _host], resource.id)
      |> Repo.all()

    host_ids =
      Host
      |> where([host], host.organization_id == ^organization_id)
      |> where([host], host.hostname in ^names or host.fqdn in ^names)
      |> select([host], host.resource_id)
      |> Repo.all()

    identifier_ids =
      ResourceIdentifier
      |> join(:left, [identifier], host in Host, on: host.resource_id == identifier.resource_id)
      |> where([identifier, _host], identifier.organization_id == ^organization_id)
      |> where([identifier, host], is_nil(host.id))
      |> where([identifier, _host], identifier.kind in ["hostname", "fqdn"])
      |> where([identifier, _host], identifier.normalized_value in ^names)
      |> select([identifier, _host], identifier.resource_id)
      |> Repo.all()

    Enum.uniq(resource_ids ++ host_ids ++ identifier_ids)
  end

  defp stable_port_interfaces(_organization_id, _resource_ids, %{
         remote_port_id_kind: kind
       })
       when kind in ["local", "name"],
       do: []

  defp stable_port_interfaces(organization_id, resource_ids, evidence) do
    case {NeighborIdentifier.mac_address?(evidence.remote_port_id),
          MacAddress.cast(evidence.remote_port_id)} do
      {true, {:ok, mac}} ->
        Interface
        |> where([interface], interface.organization_id == ^organization_id)
        |> where([interface], interface.status != "not_present")
        |> maybe_limit_resources(resource_ids)
        |> where(
          [interface],
          interface.mac_address == ^mac
        )
        |> Repo.all()

      _not_a_mac_port_id ->
        []
    end
  end

  defp named_port_interfaces(organization_id, resource_ids, evidence) do
    names =
      [
        identifier_name_hint(evidence.remote_port_id_kind, evidence.remote_port_id),
        evidence.remote_port_description
      ]
      |> Enum.reject(&is_nil/1)
      |> Enum.map(&String.trim/1)
      |> Enum.uniq()

    Interface
    |> where([interface], interface.organization_id == ^organization_id)
    |> where([interface], interface.status != "not_present")
    |> where([interface], interface.resource_id in ^resource_ids and interface.name in ^names)
    |> compatible_with_reported_port_mac(evidence)
    |> Repo.all()
  end

  defp compatible_with_reported_port_mac(query, evidence) do
    case reported_port_mac(evidence) do
      {:ok, mac} ->
        where(query, [interface], is_nil(interface.mac_address) or interface.mac_address == ^mac)

      :error ->
        query
    end
  end

  defp reported_port_mac(evidence) do
    if evidence.remote_port_id_kind in [nil, "mac_address"] and
         NeighborIdentifier.mac_address?(evidence.remote_port_id) do
      MacAddress.cast(evidence.remote_port_id)
    else
      :error
    end
  end

  defp identifier_name_hint(kind, _value) when kind in ["mac_address", "network_address"],
    do: nil

  defp identifier_name_hint(nil, value) do
    if NeighborIdentifier.mac_address?(value), do: nil, else: value
  end

  defp identifier_name_hint(_kind, value), do: value

  defp maybe_limit_resources(query, :all), do: query

  defp maybe_limit_resources(query, resource_ids),
    do: where(query, [interface], interface.resource_id in ^resource_ids)

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
    |> join(:inner, [evidence, _match], local in Interface,
      on: local.id == evidence.local_interface_id
    )
    |> join(:inner, [_evidence, match, _local], remote in Interface,
      on: remote.id == match.remote_interface_id
    )
    |> where([evidence, _match, _local, _remote], evidence.organization_id == ^organization_id)
    |> where(
      [evidence, match, local, remote],
      is_nil(evidence.stale_at) and match.status == "matched" and
        local.status != "not_present" and remote.status != "not_present"
    )
    |> select([evidence, match, _local, _remote], {evidence, match.remote_interface_id})
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
      primary = items |> Enum.map(&elem(&1, 0)) |> Enum.max_by(&primary_evidence_order/1)

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
    |> Enum.sort(&adjacency_precedes?/2)
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

  defp adjacency_precedes?(first, second) do
    first_confidence = if first.confidence == "reciprocal", do: 0, else: 1
    second_confidence = if second.confidence == "reciprocal", do: 0, else: 1
    first_evidence = evidence_order(first.primary)
    second_evidence = evidence_order(second.primary)

    cond do
      first_confidence != second_confidence ->
        first_confidence < second_confidence

      first_evidence != second_evidence ->
        first_evidence > second_evidence

      first.interface_a_id != second.interface_a_id ->
        first.interface_a_id < second.interface_a_id

      true ->
        first.interface_b_id <= second.interface_b_id
    end
  end

  defp reconcile_findings(organization_id, observed_at, adjacencies, newly_expired_ids) do
    evidence = latest_neighbor_evidence(organization_id, newly_expired_ids)
    matches = neighbor_matches(organization_id, evidence)
    boundaries = latest_neighbor_boundaries(organization_id, evidence)

    findings =
      ambiguous_findings(evidence, matches, observed_at) ++
        conflicting_findings(evidence, matches, observed_at) ++
        asymmetric_findings(adjacencies, observed_at) ++
        expired_findings(evidence, boundaries, observed_at)

    grouped = Enum.group_by(findings, & &1.interface_id)

    existing =
      TopologyFinding
      |> where([finding], finding.organization_id == ^organization_id)
      |> where([finding], finding.status == "open" and finding.kind in ^@finding_kinds)
      |> Repo.all()
      |> Enum.group_by(& &1.interface_id)

    (Map.keys(grouped) ++ Map.keys(existing))
    |> Enum.uniq()
    |> Enum.each(fn interface_id ->
      desired = Map.get(grouped, interface_id, [])
      keys = MapSet.new(desired, &{&1.kind, &1.resolution_key})

      existing_by_key =
        Map.new(Map.get(existing, interface_id, []), &{{&1.kind, &1.resolution_key}, &1})

      Enum.each(desired, fn attrs ->
        put_finding(
          organization_id,
          interface_id,
          attrs,
          Map.get(existing_by_key, {attrs.kind, attrs.resolution_key})
        )
      end)

      existing_by_key
      |> Map.values()
      |> Enum.reject(&MapSet.member?(keys, {&1.kind, &1.resolution_key}))
      |> Enum.each(&resolve_finding(&1, observed_at))
    end)
  end

  defp latest_neighbor_evidence(organization_id, newly_expired_ids) do
    tracked_expired_ids =
      TopologyFinding
      |> where(
        [finding],
        finding.organization_id == ^organization_id and finding.status == "open" and
          finding.kind == "expired_adjacency"
      )
      |> select([finding], fragment("?->>'evidence_id'", finding.details))
      |> Repo.all()
      |> Kernel.++(newly_expired_ids)
      |> Enum.uniq()

    InterfaceNeighborEvidence
    |> join(:inner, [item], interface in Interface, on: interface.id == item.local_interface_id)
    |> where(
      [item, interface],
      item.organization_id == ^organization_id and interface.status != "not_present"
    )
    |> current_or_tracked_evidence(tracked_expired_ids)
    |> latest_evidence_query()
    |> Repo.all()
  end

  defp current_or_tracked_evidence(query, []),
    do: where(query, [item, _interface], is_nil(item.stale_at))

  defp current_or_tracked_evidence(query, ids),
    do: where(query, [item, _interface], is_nil(item.stale_at) or item.id in ^ids)

  defp latest_evidence_query(query) do
    query
    |> distinct(
      [item],
      [
        item.source_id,
        item.local_interface_id,
        item.protocol,
        item.remote_chassis_id_kind,
        item.remote_chassis_id_normalized,
        item.remote_port_id_kind,
        item.remote_port_id_normalized
      ]
    )
    |> order_by(
      [item],
      asc: item.source_id,
      asc: item.local_interface_id,
      asc: item.protocol,
      asc: item.remote_chassis_id_kind,
      asc: item.remote_chassis_id_normalized,
      asc: item.remote_port_id_kind,
      asc: item.remote_port_id_normalized,
      desc: item.observed_at,
      desc: item.observation_id
    )
  end

  defp latest_neighbor_boundaries(organization_id, evidence) do
    resources =
      interface_resources(organization_id, Enum.map(evidence, & &1.local_interface_id))

    evidence
    |> Enum.map(&{&1.source_id, resources[&1.local_interface_id]})
    |> Enum.reject(fn {_source_id, resource_id} -> is_nil(resource_id) end)
    |> Enum.uniq()
    |> Map.new(fn {source_id, resource_id} = key ->
      {key, latest_boundary(organization_id, resource_id, source_id)}
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
        evidence_identity_key(item),
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
        &(is_nil(&1.stale_at) and match?(%{status: "matched"}, Map.get(matches, &1.id)))
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

  defp expired_findings(evidence, boundaries, observed_at) do
    organization_id = evidence |> List.first() |> then(&(&1 && &1.organization_id))

    interface_resources =
      interface_resources(organization_id, Enum.map(evidence, & &1.local_interface_id))

    evidence
    |> Enum.filter(fn item ->
      boundary =
        Map.get(boundaries, {item.source_id, interface_resources[item.local_interface_id]})

      item.stale_reason == "expired" and
        (is_nil(boundary) or evidence_order(item) >= evidence_order(boundary))
    end)
    |> Enum.map(fn item ->
      neighbor_finding(
        item.local_interface_id,
        "expired_adjacency",
        evidence_identity_key(item),
        "Latest neighbor evidence has expired",
        %{"evidence_id" => item.id},
        observed_at
      )
    end)
  end

  defp interface_resources(_organization_id, []), do: %{}

  defp interface_resources(organization_id, interface_ids) do
    Interface
    |> where(
      [interface],
      interface.organization_id == ^organization_id and
        interface.id in ^Enum.uniq(interface_ids)
    )
    |> select([interface], {interface.id, interface.resource_id})
    |> Repo.all()
    |> Map.new()
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

  defp put_finding(organization_id, interface_id, attrs, existing) do
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

  defp primary_evidence_order(item) do
    {
      evidence_order(item),
      item.protocol,
      item.remote_chassis_id_kind || "",
      item.remote_chassis_id_normalized,
      item.remote_port_id_kind || "",
      item.remote_port_id_normalized,
      item.id
    }
  end

  defp evidence_identity(item) do
    {
      item.source_id,
      item.local_interface_id,
      item.protocol,
      item.remote_chassis_id_kind,
      item.remote_chassis_id_normalized,
      item.remote_port_id_kind,
      item.remote_port_id_normalized
    }
  end

  defp evidence_identity_key(item) do
    item
    |> evidence_identity()
    |> :erlang.term_to_binary()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  defp max_datetime(first, second),
    do: if(DateTime.compare(first, second) == :lt, do: second, else: first)

  defp where_nullable(query, field_name, nil),
    do: where(query, [item], is_nil(field(item, ^field_name)))

  defp where_nullable(query, field_name, value),
    do: where(query, [item], field(item, ^field_name) == ^value)

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
