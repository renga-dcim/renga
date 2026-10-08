defmodule Renga.DCIM.Elevation do
  @moduledoc """
  What a rack elevation shows (RFD 8, "Places"), computed in one place so the
  page, its phone layout, and drag-to-place agree on it.

    * `front` and `rear` - one block per placed device spanning its units.
      A full-depth device occupies both faces, so it appears on each.
    * `observed` - devices seen in this rack but recorded somewhere else:
      placement evidence that resolves here while a person's confirmed
      placement says otherwise, or an LLDP neighbor that is a switch in
      this rack. Each can be placed here in one step.
    * `placeable` - what can go in the rack: devices already in it without
      a unit (a top of rack rule puts them there), devices at the rack's
      location or site without a rack, and devices not placed anywhere.

  Heights come from each device's catalog hardware type, then its current
  placement, then one unit.
  """

  import Ecto.Query, warn: false

  alias Renga.Accounts.Scope
  alias Renga.Catalog.HardwareAssignment
  alias Renga.Catalog.TypeRevision
  alias Renga.DCIM
  alias Renga.DCIM.CurrentPlacement
  alias Renga.DCIM.DesiredPlacement
  alias Renga.DCIM.PlacementEvidence
  alias Renga.DCIM.PlacementFinding
  alias Renga.DCIM.Rack
  alias Renga.Inventory.Interface
  alias Renga.Inventory.Resource
  alias Renga.Repo
  alias Renga.Topology.InterfaceNeighborEvidence
  alias Renga.Topology.InterfaceNeighborMatch
  alias Renga.Triage

  # Findings that mean evidence points somewhere the current placement is not.
  @disagreement_kinds ~w(confirmed_placement_conflict source_disagreement multiple_current_placements)
  # Fully unplaced devices are listed for convenience, not as a full inventory.
  @unplaced_limit 50

  defstruct [
    :rack,
    front: [],
    rear: [],
    observed: [],
    in_rack: [],
    at_location: [],
    unplaced: [],
    unplaced_total: 0
  ]

  @doc "Builds the elevation of a rack in the caller's organization."
  def build(%Scope{} = scope, %Rack{} = rack) do
    occupancies = DCIM.list_rack_occupancies(scope.organization_id, rack.id)
    rack_placements = rack_placements(scope, rack)
    observed = observed(scope, rack)
    observed_ids = MapSet.new(observed, & &1.resource.id)
    {unplaced, unplaced_total} = unplaced(scope, observed_ids)

    in_rack =
      rack_placements
      |> Enum.filter(&is_nil(&1.position))
      |> Enum.map(& &1.resource)

    at_location =
      scope
      |> at_location(rack)
      |> Enum.reject(&MapSet.member?(observed_ids, &1.id))

    heights =
      heights(
        scope,
        Enum.map(observed, & &1.resource.id) ++
          Enum.map(in_rack ++ at_location ++ unplaced, & &1.id)
      )

    planned =
      planned_elsewhere(scope, rack, Enum.map(occupancies, & &1.current_placement.resource_id))

    %__MODULE__{
      rack: rack,
      front: blocks(occupancies, "front", planned),
      rear: blocks(occupancies, "rear", planned),
      observed:
        Enum.map(
          observed,
          &Map.put(&1, :height, &1.height || Map.get(heights, &1.resource.id, 1))
        ),
      in_rack: Enum.map(in_rack, &placeable(&1, heights)),
      at_location: Enum.map(at_location, &placeable(&1, heights)),
      unplaced: Enum.map(unplaced, &placeable(&1, heights)),
      unplaced_total: unplaced_total
    }
  end

  @doc """
  Rack units, top first, where a device of `height` units can start on
  `face` without overlapping another device. A full-depth device needs the
  units free on both faces.
  """
  def free_positions(%__MODULE__{rack: rack} = elevation, height, face) do
    taken = taken_units(elevation, face)
    last_start = rack.height_units - height + 1

    if last_start < 1 do
      []
    else
      for start <- last_start..1//-1,
          Enum.all?(start..(start + height - 1), &(not MapSet.member?(taken, &1))),
          do: start
    end
  end

  @doc "Whether no block covers `unit` on `face`."
  def free_unit?(%__MODULE__{} = elevation, unit, face),
    do: not MapSet.member?(taken_units(elevation, face), unit)

  @doc "How many units the rack has free on a face."
  def free_count(%__MODULE__{rack: rack} = elevation, face),
    do: rack.height_units - MapSet.size(taken_units(elevation, face))

  defp taken_units(elevation, "full"),
    do: MapSet.union(taken_units(elevation, "front"), taken_units(elevation, "rear"))

  defp taken_units(elevation, face) do
    elevation
    |> Map.fetch!(String.to_existing_atom(face))
    |> Enum.flat_map(&Enum.to_list(&1.position..(&1.position + &1.height - 1)))
    |> MapSet.new()
  end

  ## Blocks

  defp blocks(occupancies, face, planned) do
    occupancies
    |> Enum.filter(&(&1.face == face))
    |> Enum.map(fn occupancy ->
      placement = occupancy.current_placement

      %{
        id: "#{face}-#{placement.id}",
        resource: placement.resource,
        placement: placement,
        position: occupancy.units.lower,
        height: occupancy.units.upper - occupancy.units.lower,
        face: placement.face,
        status: status(placement),
        planned_rack: Map.get(planned, placement.resource_id)
      }
    end)
    |> Enum.sort_by(& &1.position, :desc)
  end

  defp status(%{confirmed: true}), do: :confirmed
  defp status(%{evidence_stale?: true}), do: :stale
  defp status(%{evidence_observed_at: %DateTime{}}), do: :observed
  defp status(_placement), do: :inferred

  # A planned move to another rack, so the block can say where it is going.
  defp planned_elsewhere(_scope, _rack, []), do: %{}

  defp planned_elsewhere(%Scope{organization_id: organization_id}, rack, resource_ids) do
    DesiredPlacement
    |> where([desired], desired.organization_id == ^organization_id)
    |> where([desired], desired.resource_id in ^resource_ids)
    |> where([desired], not is_nil(desired.rack_id) and desired.rack_id != ^rack.id)
    |> preload(rack: :resource)
    |> Repo.all()
    |> Map.new(&{&1.resource_id, &1.rack})
  end

  ## Observed elsewhere

  defp observed(scope, rack) do
    evidence = observed_by_evidence(scope, rack)
    seen = MapSet.new(evidence, & &1.resource.id)

    lldp =
      scope
      |> observed_by_lldp(rack)
      |> Enum.reject(&MapSet.member?(seen, &1.resource.id))

    Enum.sort_by(evidence ++ lldp, & &1.resource.name)
  end

  # Evidence only fails to move a device when a person confirmed it
  # elsewhere or sources disagree, and both leave an open finding, so
  # those are the only devices worth resolving.
  defp observed_by_evidence(%Scope{organization_id: organization_id} = scope, rack) do
    candidates =
      from finding in PlacementFinding,
        where: finding.organization_id == ^organization_id,
        where: finding.status == "open" and finding.kind in ^@disagreement_kinds,
        select: finding.resource_id

    PlacementEvidence
    |> where([evidence], evidence.organization_id == ^organization_id)
    |> where([evidence], evidence.resource_id in subquery(candidates))
    |> where([evidence], is_nil(evidence.stale_at) and not is_nil(evidence.rack_identifier))
    |> order_by([evidence],
      desc: evidence.confidence,
      desc: evidence.observed_at,
      desc: evidence.id
    )
    |> preload(:source)
    |> Repo.all()
    |> Enum.flat_map(fn evidence ->
      case DCIM.resolve_placement_evidence(scope, evidence) do
        {:ok, %{rack_id: rack_id} = attrs, evidence} when rack_id == rack.id ->
          [{attrs, evidence}]

        _elsewhere ->
          []
      end
    end)
    |> Enum.uniq_by(fn {_attrs, evidence} -> evidence.resource_id end)
    |> with_recorded(scope, rack, fn {_attrs, evidence} -> evidence.resource_id end)
    |> Enum.map(fn {{attrs, evidence}, resource, recorded} ->
      %{
        resource: resource,
        via: :evidence,
        source: evidence.source,
        observed_at: evidence.observed_at,
        position: attrs.position,
        height: attrs.height_units,
        face: attrs.face,
        recorded: recorded
      }
    end)
  end

  defp observed_by_lldp(%Scope{organization_id: organization_id} = scope, rack) do
    organization_id
    |> lldp_neighbor_ids(rack)
    |> with_recorded(scope, rack, & &1)
    |> Enum.map(fn {_id, resource, recorded} ->
      %{
        resource: resource,
        via: :lldp,
        source: nil,
        observed_at: nil,
        position: nil,
        height: nil,
        face: nil,
        recorded: recorded
      }
    end)
  end

  @doc false
  def observed_by_lldp?(%Scope{organization_id: organization_id}, %Rack{} = rack, resource_id),
    do: resource_id in lldp_neighbor_ids(organization_id, rack)

  # Devices whose current LLDP neighbor is a switch placed in this rack.
  defp lldp_neighbor_ids(organization_id, rack) do
    from(evidence in subquery(current_neighbors(organization_id)),
      join: remote in Interface,
      on:
        remote.id == evidence.remote_interface_id and remote.organization_id == ^organization_id,
      join: switch in Resource,
      on: switch.id == remote.resource_id and switch.kind == "switch",
      join: placement in CurrentPlacement,
      on: placement.resource_id == switch.id and placement.rack_id == ^rack.id,
      join: local in Resource,
      on: local.id == evidence.resource_id,
      # A switch's neighbor is usually its uplink, not a device in its rack.
      where: local.kind != "switch" and local.lifecycle_state != "retired",
      distinct: true,
      select: evidence.resource_id
    )
    |> Repo.all()
  end

  # Unexpired LLDP evidence matched to a remote interface, per local device.
  defp current_neighbors(organization_id) do
    now = Renga.Time.utc_now_ms()

    from interface in Interface,
      join: evidence in InterfaceNeighborEvidence,
      on:
        evidence.local_interface_id == interface.id and
          evidence.organization_id == ^organization_id,
      join: match in InterfaceNeighborMatch,
      on:
        match.interface_neighbor_evidence_id == evidence.id and
          match.organization_id == ^organization_id and match.status == "matched",
      where: interface.organization_id == ^organization_id and is_nil(evidence.stale_at),
      where: is_nil(evidence.expires_at) or evidence.expires_at > ^now,
      select: %{
        resource_id: interface.resource_id,
        remote_interface_id: match.remote_interface_id
      }
  end

  # Pairs each item with its resource and where it is recorded now, and
  # drops items already recorded in this rack.
  defp with_recorded(items, %Scope{organization_id: organization_id}, rack, resource_id) do
    ids = items |> Enum.map(resource_id) |> Enum.uniq()

    resources =
      Resource
      |> where([resource], resource.organization_id == ^organization_id and resource.id in ^ids)
      |> Repo.all()
      |> Map.new(&{&1.id, &1})

    recorded =
      CurrentPlacement
      |> where([placement], placement.organization_id == ^organization_id)
      |> where([placement], placement.resource_id in ^ids)
      |> preload(site: :resource, location: :resource, rack: :resource)
      |> Repo.all()
      |> Map.new(&{&1.resource_id, &1})

    Enum.flat_map(items, fn item ->
      id = resource_id.(item)
      placement = Map.get(recorded, id)

      case Map.get(resources, id) do
        nil -> []
        _resource when placement != nil and placement.rack_id == rack.id -> []
        resource -> [{item, resource, placement}]
      end
    end)
  end

  ## Placeable

  defp rack_placements(%Scope{organization_id: organization_id}, rack) do
    CurrentPlacement
    |> where([placement], placement.organization_id == ^organization_id)
    |> where([placement], placement.rack_id == ^rack.id)
    |> preload(:resource)
    |> Repo.all()
  end

  # Placed at the rack's location, or at its site without a location, but
  # not in any rack yet.
  defp at_location(%Scope{organization_id: organization_id}, rack) do
    near_rack =
      if rack.location_id,
        do:
          dynamic(
            [placement],
            placement.location_id == ^rack.location_id or is_nil(placement.location_id)
          ),
        else: dynamic([placement], is_nil(placement.location_id))

    CurrentPlacement
    |> where([placement], placement.organization_id == ^organization_id)
    |> where([placement], is_nil(placement.rack_id) and placement.site_id == ^rack.site_id)
    |> where(^near_rack)
    |> join(:inner, [placement], resource in assoc(placement, :resource))
    |> where([_placement, resource], resource.lifecycle_state != "retired")
    |> order_by([_placement, resource], asc: resource.name)
    |> select([_placement, resource], resource)
    |> Repo.all()
  end

  defp unplaced(%Scope{organization_id: organization_id}, observed_ids) do
    query =
      from resource in Resource,
        left_join: placement in CurrentPlacement,
        on:
          placement.resource_id == resource.id and
            placement.organization_id == ^organization_id,
        where: resource.organization_id == ^organization_id,
        where: resource.kind in ^Triage.kinds() and resource.lifecycle_state != "retired",
        where: is_nil(placement.id),
        where: resource.id not in ^MapSet.to_list(observed_ids)

    {query |> order_by([resource], asc: resource.name) |> limit(@unplaced_limit) |> Repo.all(),
     Repo.aggregate(query, :count)}
  end

  defp placeable(resource, heights),
    do: %{resource: resource, height: Map.get(heights, resource.id, 1)}

  @doc false
  # Catalog heights take precedence over recorded geometry for every placing UI.
  def heights(%Scope{organization_id: organization_id}, resource_ids) do
    recorded =
      CurrentPlacement
      |> where([placement], placement.organization_id == ^organization_id)
      |> where([placement], placement.resource_id in ^Enum.uniq(resource_ids))
      |> where([placement], not is_nil(placement.height_units))
      |> select([placement], {placement.resource_id, placement.height_units})
      |> Repo.all()
      |> Map.new()

    catalog =
      HardwareAssignment
      |> join(:inner, [assignment], revision in TypeRevision,
        on: revision.id == assignment.catalog_type_revision_id
      )
      |> where([assignment], assignment.organization_id == ^organization_id)
      |> where([assignment], assignment.resource_id in ^Enum.uniq(resource_ids))
      |> where([_assignment, revision], not is_nil(revision.height_units))
      |> select([assignment, revision], {assignment.resource_id, revision.height_units})
      |> Repo.all()
      |> Map.new()

    Map.merge(recorded, catalog)
  end
end
