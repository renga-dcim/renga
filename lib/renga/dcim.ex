defmodule Renga.DCIM do
  @moduledoc """
  Organization-scoped physical containment, placement, and rack occupancy.

  Canonical placement is intentionally separate from source evidence and
  operator intent. Database constraints remain the final guard for tenant,
  same-site, geometry, and face-specific overlap invariants.
  """

  import Ecto.Query, warn: false

  alias Renga.Accounts.Organization
  alias Renga.Accounts.OrganizationMembership
  alias Renga.Accounts.Scope
  alias Renga.DCIM.CurrentPlacement
  alias Renga.DCIM.DesiredPlacement
  alias Renga.DCIM.Location
  alias Renga.DCIM.PlacementEvidence
  alias Renga.DCIM.PlacementFinding
  alias Renga.DCIM.Rack
  alias Renga.DCIM.RackOccupancy
  alias Renga.DCIM.Site
  alias Renga.DCIM.SiteGroup
  alias Renga.Inventory
  alias Renga.Inventory.Observation
  alias Renga.Inventory.Resource
  alias Renga.Inventory.ResourceIdentifier
  alias Renga.Inventory.Source
  alias Renga.Repo

  @hierarchy_lock "dcim-hierarchy"

  def list_sites(%Scope{organization_id: organization_id}) do
    Site
    |> where([site], site.organization_id == ^organization_id)
    |> join(:inner, [site], resource in assoc(site, :resource))
    |> order_by([_site, resource], asc: resource.name)
    |> preload([site, resource], resource: resource)
    |> Repo.all()
  end

  def list_site_groups(%Scope{organization_id: organization_id}) do
    SiteGroup
    |> where([group], group.organization_id == ^organization_id)
    |> join(:inner, [group], resource in assoc(group, :resource))
    |> order_by([_group, resource], asc: resource.name)
    |> preload([group, resource], resource: resource, parent: :resource)
    |> Repo.all()
  end

  def get_site!(%Scope{organization_id: organization_id}, id) do
    Site
    |> where([site], site.organization_id == ^organization_id and site.id == ^id)
    |> preload([:resource, locations: :resource, racks: [:resource, :location]])
    |> Repo.one!()
  end

  def list_locations(%Scope{organization_id: organization_id}, site_id \\ nil) do
    Location
    |> where([location], location.organization_id == ^organization_id)
    |> maybe_where_site(site_id)
    |> join(:inner, [location], resource in assoc(location, :resource))
    |> order_by([_location, resource], asc: resource.name)
    |> preload([location, resource], resource: resource, parent: :resource, site: :resource)
    |> Repo.all()
  end

  def get_location!(%Scope{organization_id: organization_id}, id) do
    Location
    |> where([location], location.organization_id == ^organization_id and location.id == ^id)
    |> preload([
      :resource,
      site: :resource,
      parent: :resource,
      children: :resource,
      racks: :resource
    ])
    |> Repo.one!()
  end

  def list_racks(%Scope{organization_id: organization_id}) do
    Rack
    |> where([rack], rack.organization_id == ^organization_id)
    |> join(:inner, [rack], resource in assoc(rack, :resource))
    |> order_by([_rack, resource], asc: resource.name)
    |> preload([rack, resource], resource: resource, site: :resource, location: :resource)
    |> Repo.all()
  end

  def get_rack!(%Scope{organization_id: organization_id}, id) do
    Rack
    |> where([rack], rack.organization_id == ^organization_id and rack.id == ^id)
    |> preload([:resource, site: :resource, location: :resource])
    |> Repo.one!()
    |> then(fn rack -> %{rack | occupancies: list_rack_occupancies(organization_id, rack.id)} end)
  end

  def list_rack_occupancies(organization_id, rack_id) do
    RackOccupancy
    |> where(
      [occupancy],
      occupancy.organization_id == ^organization_id and occupancy.rack_id == ^rack_id
    )
    |> join(:inner, [occupancy], placement in CurrentPlacement,
      on: placement.id == occupancy.current_placement_id
    )
    |> join(:inner, [_occupancy, placement], resource in Resource,
      on: resource.id == placement.resource_id
    )
    |> order_by([occupancy], desc: fragment("lower(?)", occupancy.units))
    |> preload([occupancy, placement, resource],
      current_placement: {placement, resource: resource}
    )
    |> Repo.all()
    |> hydrate_occupancy_evidence()
  end

  def create_site_group(%Scope{} = scope, resource_attrs, attrs \\ %{}) do
    managed_transaction(scope, fn ->
      lock_hierarchy(scope.organization_id)
      parent_id = attr(attrs, :parent_id)
      if parent_id, do: get_site_group!(scope, parent_id)
      create_projection(scope, SiteGroup, "site_group", resource_attrs, attrs)
    end)
  end

  def create_site(%Scope{} = scope, resource_attrs, attrs) do
    managed_transaction(scope, fn ->
      create_projection(scope, Site, "site", resource_attrs, attrs)
    end)
  end

  def update_site_group(%Scope{} = scope, %SiteGroup{} = group, attrs) do
    managed_transaction(scope, fn ->
      lock_hierarchy(scope.organization_id)
      stored = scoped_lock!(SiteGroup, scope.organization_id, group.id)
      parent_id = attr(attrs, :parent_id)
      validate_site_group_parent!(scope, stored.id, parent_id)
      update_or_rollback(SiteGroup.changeset(stored, attrs))
    end)
  end

  def create_location(%Scope{} = scope, resource_attrs, attrs) do
    managed_transaction(scope, fn ->
      lock_hierarchy(scope.organization_id)
      validate_location_parent!(scope, nil, attr(attrs, :site_id), attr(attrs, :parent_id))
      create_projection(scope, Location, "location", resource_attrs, attrs)
    end)
  end

  def create_rack(%Scope{} = scope, resource_attrs, attrs) do
    managed_transaction(scope, fn ->
      create_projection(scope, Rack, "rack", resource_attrs, attrs)
    end)
  end

  def update_location(%Scope{} = scope, %Location{} = location, attrs) do
    managed_transaction(scope, fn ->
      lock_hierarchy(scope.organization_id)
      stored = scoped_lock!(Location, scope.organization_id, location.id)
      site_id = attr(attrs, :site_id) || stored.site_id
      parent_id = attr(attrs, :parent_id)
      validate_location_parent!(scope, stored.id, site_id, parent_id)
      update_or_rollback(Location.changeset(stored, attrs))
    end)
  end

  def update_rack(%Scope{} = scope, %Rack{} = rack, attrs) do
    managed_transaction(scope, fn ->
      stored = lock_rack!(scope.organization_id, rack.id)
      changeset = Rack.changeset(stored, attrs)
      new_height = Ecto.Changeset.get_field(changeset, :height_units)
      new_site_id = Ecto.Changeset.get_field(changeset, :site_id)
      new_location_id = Ecto.Changeset.get_field(changeset, :location_id)

      containment_changed? =
        new_site_id != stored.site_id or new_location_id != stored.location_id

      if containment_changed? and rack_has_placements?(scope.organization_id, stored.id),
        do: Repo.rollback(:rack_has_placements)

      outside? =
        RackOccupancy
        |> where([occupancy], occupancy.rack_id == ^stored.id)
        |> where([occupancy], fragment("upper(?) - 1 > ?", occupancy.units, ^new_height))
        |> Repo.exists?()

      if outside?, do: Repo.rollback(:occupied_units_out_of_bounds)
      updated = update_or_rollback(changeset)

      if Ecto.Changeset.changed?(changeset, :height_units),
        do: refresh_desired_findings(scope, [stored.id])

      updated
    end)
  end

  def put_desired_placement(%Scope{} = scope, resource_id, attrs) do
    managed_transaction(scope, fn ->
      resource = lock_resource!(scope.organization_id, resource_id)

      placement =
        Repo.get_by(DesiredPlacement,
          organization_id: scope.organization_id,
          resource_id: resource.id
        ) || %DesiredPlacement{organization_id: scope.organization_id, resource_id: resource.id}

      effective_rack_id = effective_rack_id(placement, attrs)

      locked_racks =
        [placement.rack_id, effective_rack_id]
        |> Enum.reject(&is_nil/1)
        |> Enum.uniq()
        |> Enum.sort()
        |> Map.new(fn id -> {id, lock_rack!(scope.organization_id, id)} end)

      rack = if effective_rack_id, do: Map.fetch!(locked_racks, effective_rack_id)
      attrs = canonicalize_placement(attrs, rack)
      placement = placement |> DesiredPlacement.changeset(attrs) |> upsert_or_rollback()
      reconcile_blocked_move(scope, placement, rack)
      placement
    end)
  end

  def put_current_placement(%Scope{} = scope, resource_id, attrs) do
    managed_transaction(scope, fn -> do_put_current_placement(scope, resource_id, attrs) end)
  end

  def remove_current_placement(%Scope{} = scope, resource_id) do
    managed_transaction(scope, fn ->
      lock_resource!(scope.organization_id, resource_id)

      placement =
        CurrentPlacement
        |> where([placement], placement.organization_id == ^scope.organization_id)
        |> where([placement], placement.resource_id == ^resource_id)
        |> Repo.one()

      case placement do
        nil ->
          :ok

        placement ->
          if placement.rack_id, do: lock_rack!(scope.organization_id, placement.rack_id)
          deleted = Repo.delete!(placement)
          refresh_desired_findings(scope, [placement.rack_id])
          deleted
      end
    end)
  end

  def list_unplaced_resources(%Scope{organization_id: organization_id}) do
    Resource
    |> where([resource], resource.organization_id == ^organization_id)
    |> where([resource], resource.kind in ~w(server switch pdu storage unknown))
    |> where([resource], resource.lifecycle_state != "retired")
    |> join(:left, [resource], placement in CurrentPlacement,
      on:
        placement.resource_id == resource.id and
          placement.organization_id == resource.organization_id
    )
    |> where([_resource, placement], is_nil(placement.id))
    |> order_by([resource], asc: resource.name)
    |> Repo.all()
  end

  def create_placement_evidence(%Scope{} = scope, source_id, observation_id, resource_id, attrs) do
    reconciliation_transaction(scope, fn ->
      source = scoped_get!(Source, scope.organization_id, source_id)

      observation =
        Observation
        |> where([observation], observation.organization_id == ^scope.organization_id)
        |> where([observation], observation.source_id == ^source.id)
        |> Repo.get!(observation_id)

      resource = Inventory.get_resource!(scope, resource_id)

      %PlacementEvidence{
        organization_id: scope.organization_id,
        source_id: source.id,
        observation_id: observation.id,
        resource_id: resource.id
      }
      |> PlacementEvidence.changeset(attrs)
      |> insert_or_rollback()
    end)
  end

  def mark_placement_evidence_stale(
        %Scope{} = scope,
        source_id,
        stale_at \\ Renga.Time.utc_now_ms()
      ) do
    reconciliation_transaction(scope, fn ->
      scoped_get!(Source, scope.organization_id, source_id)

      PlacementEvidence
      |> where([evidence], evidence.organization_id == ^scope.organization_id)
      |> where([evidence], evidence.source_id == ^source_id and is_nil(evidence.stale_at))
      |> Repo.update_all(set: [stale_at: stale_at])
    end)
  end

  @doc """
  Stales evidence omitted from an explicitly complete placement snapshot.

  Partial observations have no absence meaning and are rejected. The accepted
  observation declares completeness at
  `payload.section_completeness.placement`; callers provide the resources that
  were present in that section.
  """
  def mark_omitted_placement_evidence_stale(
        %Scope{} = scope,
        source_id,
        observation_id,
        observed_resource_ids
      ) do
    reconciliation_transaction(scope, fn ->
      source = scoped_get!(Source, scope.organization_id, source_id)

      if source.metadata["placement_snapshot_policy"] != "complete",
        do: Repo.rollback(:source_not_complete)

      observation =
        Observation
        |> where([item], item.organization_id == ^scope.organization_id)
        |> where([item], item.source_id == ^source_id and item.id == ^observation_id)
        |> Repo.one!()

      if get_in(observation.payload, ["section_completeness", "placement"]) == true do
        PlacementEvidence
        |> where([evidence], evidence.organization_id == ^scope.organization_id)
        |> where([evidence], evidence.source_id == ^source_id and is_nil(evidence.stale_at))
        |> where([evidence], evidence.observed_at < ^observation.observed_at)
        |> where([evidence], evidence.resource_id not in ^observed_resource_ids)
        |> Repo.update_all(set: [stale_at: observation.observed_at])
      else
        Repo.rollback(:incomplete_snapshot)
      end
    end)
  end

  def list_placement_findings(%Scope{organization_id: organization_id}, status \\ "open") do
    PlacementFinding
    |> where([finding], finding.organization_id == ^organization_id and finding.status == ^status)
    |> join(:inner, [finding], resource in assoc(finding, :resource))
    |> order_by([finding], desc: finding.inserted_at)
    |> preload([finding, resource], resource: resource)
    |> Repo.all()
  end

  @doc """
  Reconciles active placement assertions without overwriting confirmed state.

  The highest-confidence unambiguous assertion wins only when current placement
  is not operator-confirmed. Unknown, ambiguous, and disagreeing assertions
  remain queryable findings rather than invented placement certainty.
  """
  def reconcile_placement_evidence(%Scope{} = scope, resource_id) do
    reconciliation_transaction(scope, fn ->
      resource = lock_resource!(scope.organization_id, resource_id)

      resolutions =
        PlacementEvidence
        |> where([item], item.organization_id == ^scope.organization_id)
        |> where([item], item.resource_id == ^resource.id and is_nil(item.stale_at))
        |> order_by([item], desc: item.confidence, desc: item.observed_at, desc: item.id)
        |> Repo.all()
        |> Enum.map(&resolve_evidence(scope, &1))

      unresolved =
        Enum.filter(
          resolutions,
          &match?({status, _} when status in [:unknown, :ambiguous, :conflict], &1)
        )

      resolved = for {:ok, attrs, item} <- resolutions, do: {attrs, item}
      reconcile_resolution_findings(scope, resource.id, unresolved, resolved)

      case resolved do
        [] ->
          do_resolve_placement_finding(scope, resource.id, "confirmed_placement_conflict")
          nil

        [{attrs, item} | _] ->
          reconcile_selected_evidence(scope, resource.id, attrs, item, resolved)
      end
    end)
  end

  def put_placement_finding(%Scope{} = scope, resource_id, attrs) do
    reconciliation_transaction(scope, fn ->
      do_put_placement_finding(scope, resource_id, attrs)
    end)
  end

  def resolve_placement_finding(%Scope{} = scope, resource_id, kind) do
    reconciliation_transaction(scope, fn ->
      do_resolve_placement_finding(scope, resource_id, kind)
    end)
  end

  defp do_put_placement_finding(%Scope{} = scope, resource_id, attrs) do
    resource = Inventory.get_resource!(scope, resource_id)
    kind = attr(attrs, :kind)

    placement_finding_query(scope.organization_id, resource.id, kind)
    |> Repo.one()
    |> case do
      nil -> %PlacementFinding{organization_id: scope.organization_id, resource_id: resource.id}
      finding -> finding
    end
    |> PlacementFinding.changeset(attrs)
    |> upsert()
  end

  defp do_resolve_placement_finding(%Scope{} = scope, resource_id, kind) do
    placement_finding_query(scope.organization_id, resource_id, kind)
    |> Repo.one()
    |> case do
      nil ->
        {:ok, nil}

      finding ->
        finding
        |> PlacementFinding.changeset(%{status: "resolved", resolved_at: Renga.Time.utc_now_ms()})
        |> Repo.update()
    end
  end

  def change_site(%Site{} = site, attrs \\ %{}), do: Site.changeset(site, attrs)

  def change_location(%Location{} = location, attrs \\ %{}),
    do: Location.changeset(location, attrs)

  def change_rack(%Rack{} = rack, attrs \\ %{}), do: Rack.changeset(rack, attrs)

  def change_placement(%DesiredPlacement{} = placement, attrs \\ %{}),
    do: DesiredPlacement.changeset(placement, attrs)

  defp create_projection(scope, module, kind, resource_attrs, attrs) do
    resource_attrs = put_attr(resource_attrs, :kind, kind)

    resource =
      case Inventory.create_resource(scope, resource_attrs) do
        {:ok, resource} -> resource
        {:error, reason} -> Repo.rollback(reason)
      end

    struct(module, organization_id: scope.organization_id, resource_id: resource.id)
    |> module.changeset(attrs)
    |> insert_or_rollback()
    |> Repo.preload(:resource)
  end

  defp do_put_current_placement(scope, resource_id, attrs) do
    resource = lock_resource!(scope.organization_id, resource_id)

    placement =
      CurrentPlacement
      |> where([placement], placement.organization_id == ^scope.organization_id)
      |> where([placement], placement.resource_id == ^resource.id)
      |> Repo.one()

    rack_id = effective_rack_id(placement, attrs)

    locked_racks =
      [placement && placement.rack_id, rack_id]
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()
      |> Enum.sort()
      |> Map.new(fn id -> {id, lock_rack!(scope.organization_id, id)} end)

    rack = if rack_id, do: Map.fetch!(locked_racks, rack_id)
    attrs = canonicalize_placement(attrs, rack)

    changeset =
      (placement ||
         %CurrentPlacement{organization_id: scope.organization_id, resource_id: resource.id})
      |> CurrentPlacement.changeset(attrs)

    if rack, do: validate_rack_bounds!(rack, changeset)

    if placement,
      do:
        Repo.delete_all(
          from occupancy in RackOccupancy, where: occupancy.current_placement_id == ^placement.id
        )

    placement =
      upsert_or_rollback(changeset)

    insert_occupancies(placement)
    refresh_desired_findings(scope, Map.keys(locked_racks))
    Repo.preload(placement, [:site, :location, :rack])
  end

  defp effective_rack_id(nil, attrs), do: attr(attrs, :rack_id)

  defp effective_rack_id(placement, attrs) do
    if attr_present?(attrs, :rack_id), do: attr(attrs, :rack_id), else: placement.rack_id
  end

  defp canonicalize_placement(attrs, nil) do
    attrs
    |> put_attr(:rack_id, nil)
    |> put_attr(:position, nil)
    |> put_attr(:height_units, nil)
    |> put_attr(:face, nil)
  end

  defp canonicalize_placement(attrs, rack) do
    attrs
    |> put_attr(:rack_id, rack.id)
    |> put_attr(:site_id, rack.site_id)
    |> put_attr(:location_id, rack.location_id)
    |> normalize_geometry()
  end

  defp normalize_geometry(attrs) do
    if attr_present?(attrs, :position) and is_nil(attr(attrs, :position)) do
      attrs
      |> put_attr(:height_units, nil)
      |> put_attr(:face, nil)
    else
      attrs
    end
  end

  defp validate_rack_bounds!(rack, changeset) do
    position = Ecto.Changeset.get_field(changeset, :position)
    height = Ecto.Changeset.get_field(changeset, :height_units)

    if position && height && to_integer(position) + to_integer(height) - 1 > rack.height_units do
      Repo.rollback(:rack_position_out_of_bounds)
    end
  end

  defp insert_occupancies(%CurrentPlacement{rack_id: nil}), do: :ok
  defp insert_occupancies(%CurrentPlacement{position: nil}), do: :ok

  defp insert_occupancies(placement) do
    range = %Postgrex.Range{
      lower: placement.position,
      upper: placement.position + placement.height_units,
      lower_inclusive: true,
      upper_inclusive: false
    }

    faces = if placement.face == "full", do: ~w(front rear), else: [placement.face]

    Enum.each(faces, fn face ->
      %RackOccupancy{
        organization_id: placement.organization_id,
        current_placement_id: placement.id,
        rack_id: placement.rack_id
      }
      |> RackOccupancy.changeset(%{face: face, units: range})
      |> insert_or_rollback()
    end)
  end

  defp hydrate_occupancy_evidence(occupancies) do
    organization_ids = occupancies |> Enum.map(& &1.organization_id) |> Enum.uniq()

    evidence_ids =
      occupancies
      |> Enum.map(&get_in(&1.current_placement.provenance, ["placement_evidence_id"]))
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()

    evidence_by_id =
      PlacementEvidence
      |> where(
        [evidence],
        evidence.organization_id in ^organization_ids and evidence.id in ^evidence_ids
      )
      |> Repo.all()
      |> Map.new(&{&1.id, &1})

    Enum.map(occupancies, fn occupancy ->
      evidence_id =
        get_in(occupancy.current_placement.provenance, ["placement_evidence_id"])

      placement =
        case Map.get(evidence_by_id, evidence_id) do
          nil ->
            occupancy.current_placement

          evidence ->
            %{
              occupancy.current_placement
              | evidence_observed_at: evidence.observed_at,
                evidence_stale?: not is_nil(evidence.stale_at)
            }
        end

      %{occupancy | current_placement: placement}
    end)
  end

  defp reconcile_blocked_move(scope, %DesiredPlacement{rack_id: nil} = placement, _rack) do
    do_resolve_placement_finding(scope, placement.resource_id, "blocked_move")
  end

  defp reconcile_blocked_move(scope, placement, rack) do
    case blocked_move_message(scope, placement, rack) do
      nil ->
        do_resolve_placement_finding(scope, placement.resource_id, "blocked_move")

      message ->
        case do_put_placement_finding(scope, placement.resource_id, %{
               kind: "blocked_move",
               message: message,
               details: %{"rack_id" => placement.rack_id}
             }) do
          {:ok, finding} -> finding
          {:error, reason} -> Repo.rollback(reason)
        end
    end
  end

  defp blocked_move_message(
         _scope,
         %{position: position, height_units: height_units},
         %{height_units: rack_height}
       )
       when is_integer(position) and is_integer(height_units) and
              position + height_units - 1 > rack_height,
       do: "Desired rack units exceed rack geometry"

  defp blocked_move_message(scope, placement, _rack) do
    if desired_units_occupied?(scope, placement),
      do: "Desired rack units are currently occupied"
  end

  defp desired_units_occupied?(_scope, %{position: nil}), do: false

  defp desired_units_occupied?(scope, placement) do
    upper = placement.position + placement.height_units
    faces = if placement.face == "full", do: ~w(front rear), else: [placement.face]

    RackOccupancy
    |> join(:inner, [occupancy], current in CurrentPlacement,
      on: current.id == occupancy.current_placement_id
    )
    |> where([occupancy], occupancy.organization_id == ^scope.organization_id)
    |> where(
      [occupancy, _current],
      occupancy.rack_id == ^placement.rack_id and occupancy.face in ^faces
    )
    |> where([_occupancy, current], current.resource_id != ^placement.resource_id)
    |> where(
      [occupancy, _current],
      fragment("? && int4range(?, ?, '[)')", occupancy.units, ^placement.position, ^upper)
    )
    |> Repo.exists?()
  end

  defp refresh_desired_findings(scope, rack_ids) do
    rack_ids
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
    |> Enum.each(fn rack_id ->
      rack = scoped_get!(Rack, scope.organization_id, rack_id)

      DesiredPlacement
      |> where([placement], placement.organization_id == ^scope.organization_id)
      |> where([placement], placement.rack_id == ^rack_id)
      |> Repo.all()
      |> Enum.each(&reconcile_blocked_move(scope, &1, rack))
    end)
  end

  defp resolve_evidence(
         scope,
         %{site_identifier: nil, rack_identifier: rack_identifier} = evidence
       )
       when not is_nil(rack_identifier) do
    case resolve_rack_globally(scope, rack_identifier) do
      {:ok, rack} ->
        case validate_rack_location_assertion(scope, rack, evidence.location_identifier) do
          :ok ->
            {:ok, evidence_attrs(evidence, rack.site_id, rack.location_id, rack.id), evidence}

          unresolved ->
            unresolved_evidence(unresolved, evidence)
        end

      unresolved ->
        unresolved_evidence(unresolved, evidence)
    end
  end

  defp resolve_evidence(
         scope,
         %{site_identifier: site_identifier, rack_identifier: rack_identifier} = evidence
       )
       when not is_nil(rack_identifier) do
    with {:ok, site} <- resolve_site(scope, site_identifier),
         {:ok, rack} <- resolve_rack_for_site(scope, site, rack_identifier),
         :ok <- validate_rack_location_assertion(scope, rack, evidence.location_identifier) do
      {:ok, evidence_attrs(evidence, site.id, rack.location_id, rack.id), evidence}
    else
      unresolved -> unresolved_evidence(unresolved, evidence)
    end
  end

  defp resolve_evidence(scope, evidence) do
    with {:ok, site} <- resolve_site(scope, evidence.site_identifier),
         {:ok, location} <- resolve_location(scope, site, evidence.location_identifier) do
      {:ok, evidence_attrs(evidence, site.id, location && location.id, nil), evidence}
    else
      unresolved -> unresolved_evidence(unresolved, evidence)
    end
  end

  defp evidence_attrs(evidence, site_id, location_id, rack_id) do
    geometry =
      if evidence.position && evidence.height_units && evidence.face do
        %{position: evidence.position, height_units: evidence.height_units, face: evidence.face}
      else
        %{position: nil, height_units: nil, face: nil}
      end

    Map.merge(
      %{
        site_id: site_id,
        location_id: location_id,
        rack_id: rack_id,
        confirmed: false,
        provenance: %{
          "placement_evidence_id" => evidence.id,
          "source_id" => evidence.source_id,
          "observation_id" => evidence.observation_id,
          "confidence" => evidence.confidence
        }
      },
      geometry
    )
  end

  defp unresolved_evidence({:unknown, identifier}, evidence),
    do: {:unknown, %{evidence: evidence, identifier: identifier}}

  defp unresolved_evidence({:ambiguous, identifier}, evidence),
    do: {:ambiguous, %{evidence: evidence, identifier: identifier}}

  defp unresolved_evidence({:conflict, identifier}, evidence),
    do: {:conflict, %{evidence: evidence, identifier: identifier}}

  defp validate_rack_location_assertion(_scope, _rack, nil), do: :ok

  defp validate_rack_location_assertion(scope, rack, identifier) do
    case resolve_location(scope, %{id: rack.site_id}, identifier) do
      {:ok, %{id: location_id}} when location_id == rack.location_id -> :ok
      {:ok, _other_location} -> {:conflict, identifier}
      unresolved -> unresolved
    end
  end

  defp resolve_site(_scope, nil), do: {:unknown, nil}

  defp resolve_site(%Scope{organization_id: organization_id}, identifier) do
    identifier_resource_ids = identifier_resource_ids(organization_id, identifier)

    Site
    |> join(:inner, [site], resource in Resource, on: resource.id == site.resource_id)
    |> where([site, _resource], site.organization_id == ^organization_id)
    |> where(
      [site, resource],
      site.slug == ^identifier or resource.name == ^identifier or
        resource.id in ^identifier_resource_ids
    )
    |> Repo.all()
    |> resolution(identifier)
  end

  defp resolve_location(_scope, _site, nil), do: {:ok, nil}

  defp resolve_location(%Scope{organization_id: organization_id}, site, identifier) do
    identifier_resource_ids = identifier_resource_ids(organization_id, identifier)

    Location
    |> join(:inner, [location], resource in Resource, on: resource.id == location.resource_id)
    |> where(
      [location, _resource],
      location.organization_id == ^organization_id and location.site_id == ^site.id
    )
    |> where(
      [_location, resource],
      resource.name == ^identifier or resource.id in ^identifier_resource_ids
    )
    |> Repo.all()
    |> resolution(identifier)
  end

  defp resolve_rack_globally(%Scope{organization_id: organization_id}, identifier) do
    identifier_resource_ids = identifier_resource_ids(organization_id, identifier)

    Rack
    |> join(:inner, [rack], resource in Resource, on: resource.id == rack.resource_id)
    |> where([rack, _resource], rack.organization_id == ^organization_id)
    |> where(
      [rack, resource],
      rack.facility_id == ^identifier or resource.name == ^identifier or
        resource.id in ^identifier_resource_ids
    )
    |> Repo.all()
    |> resolution(identifier)
  end

  defp resolve_rack_for_site(scope, site, identifier) do
    case resolve_rack(scope, site, nil, identifier) do
      {:unknown, ^identifier} ->
        case resolve_rack_globally(scope, identifier) do
          {:ok, _rack_in_another_site} -> {:conflict, identifier}
          unresolved -> unresolved
        end

      resolution ->
        resolution
    end
  end

  defp resolve_rack(_scope, _site, _location, nil), do: {:ok, nil}

  defp resolve_rack(%Scope{organization_id: organization_id}, site, location, identifier) do
    identifier_resource_ids = identifier_resource_ids(organization_id, identifier)

    Rack
    |> join(:inner, [rack], resource in Resource, on: resource.id == rack.resource_id)
    |> where(
      [rack, _resource],
      rack.organization_id == ^organization_id and rack.site_id == ^site.id
    )
    |> where(
      [rack, resource],
      rack.facility_id == ^identifier or resource.name == ^identifier or
        resource.id in ^identifier_resource_ids
    )
    |> maybe_where_location(location)
    |> Repo.all()
    |> resolution(identifier)
  end

  defp resolution([], identifier), do: {:unknown, identifier}
  defp resolution([record], _identifier), do: {:ok, record}
  defp resolution([_first | _rest], identifier), do: {:ambiguous, identifier}

  defp identifier_resource_ids(organization_id, identifier) do
    ResourceIdentifier
    |> where([item], item.organization_id == ^organization_id)
    |> where([item], fragment("lower(?)", item.normalized_value) == ^String.downcase(identifier))
    |> select([item], item.resource_id)
    |> Repo.all()
  end

  defp reconcile_resolution_findings(scope, resource_id, unresolved, resolved) do
    unknown? = Enum.any?(unresolved, &match?({:unknown, _}, &1))
    ambiguous? = Enum.any?(unresolved, &match?({:ambiguous, _}, &1))
    conflict? = Enum.any?(unresolved, &match?({:conflict, _}, &1))

    reconcile_boolean_finding(
      scope,
      resource_id,
      "unknown_location",
      unknown?,
      "Placement evidence references unknown physical containment"
    )

    reconcile_boolean_finding(
      scope,
      resource_id,
      "ambiguous_identifier",
      ambiguous?,
      "Placement evidence matches more than one physical object"
    )

    reconcile_boolean_finding(
      scope,
      resource_id,
      "containment_conflict",
      conflict?,
      "Placement evidence contains contradictory physical containment"
    )

    reconcile_boolean_finding(
      scope,
      resource_id,
      "source_disagreement",
      active_disagreement?(resolved),
      "Active placement sources disagree"
    )

    reconcile_boolean_finding(
      scope,
      resource_id,
      "multiple_current_placements",
      simultaneous_disagreement?(resolved),
      "Resource was reported in multiple places at the same observed time"
    )
  end

  defp reconcile_selected_evidence(scope, resource_id, attrs, _item, resolved) do
    current =
      Repo.get_by(CurrentPlacement,
        organization_id: scope.organization_id,
        resource_id: resource_id
      )

    conflict? = not is_nil(current) and current.confirmed and not same_placement?(current, attrs)

    reconcile_boolean_finding(
      scope,
      resource_id,
      "confirmed_placement_conflict",
      conflict?,
      "Observed placement conflicts with operator-confirmed placement"
    )

    cond do
      conflict? -> current
      active_disagreement?(resolved) -> current
      true -> do_put_current_placement(scope, resource_id, attrs)
    end
  end

  defp active_disagreement?(resolved) do
    resolved
    |> Enum.map(fn {attrs, _item} -> placement_identity(attrs) end)
    |> Enum.uniq()
    |> length()
    |> Kernel.>(1)
  end

  defp simultaneous_disagreement?(resolved) do
    resolved
    |> Enum.group_by(fn {_attrs, evidence} -> evidence.observed_at end)
    |> Enum.any?(fn {_observed_at, assertions} -> active_disagreement?(assertions) end)
  end

  defp placement_identity(attrs) do
    Map.take(attrs, [:site_id, :location_id, :rack_id, :position, :face])
  end

  defp same_placement?(current, attrs) do
    Enum.all?([:site_id, :location_id, :rack_id, :position, :height_units, :face], fn field ->
      Map.get(current, field) == Map.get(attrs, field)
    end)
  end

  defp reconcile_boolean_finding(scope, resource_id, kind, true, message) do
    case do_put_placement_finding(scope, resource_id, %{kind: kind, message: message}) do
      {:ok, finding} -> finding
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp reconcile_boolean_finding(scope, resource_id, kind, false, _message),
    do: do_resolve_placement_finding(scope, resource_id, kind)

  defp maybe_where_location(query, nil), do: query

  defp maybe_where_location(query, location),
    do: where(query, [rack], rack.location_id == ^location.id)

  defp validate_site_group_parent!(_scope, _group_id, nil), do: :ok

  defp validate_site_group_parent!(scope, group_id, parent_id) do
    scoped_get!(SiteGroup, scope.organization_id, parent_id)

    if hierarchy_descendant?("site_groups", scope.organization_id, group_id, parent_id),
      do: Repo.rollback(:hierarchy_cycle)
  end

  defp validate_location_parent!(_scope, _location_id, _site_id, nil), do: :ok

  defp validate_location_parent!(scope, location_id, site_id, parent_id) do
    parent = scoped_get!(Location, scope.organization_id, parent_id)
    if parent.site_id != site_id, do: Repo.rollback(:parent_site_mismatch)

    if location_id &&
         hierarchy_descendant?("locations", scope.organization_id, location_id, parent_id) do
      Repo.rollback(:hierarchy_cycle)
    end
  end

  defp hierarchy_descendant?(table, organization_id, parent_id, possible_descendant_id)
       when table in ["locations", "site_groups"] do
    %{rows: rows} =
      Repo.query!(
        """
        WITH RECURSIVE descendants AS (
          SELECT id FROM #{table} WHERE organization_id = $1 AND parent_id = $2
          UNION ALL
          SELECT child.id FROM #{table} child JOIN descendants d ON child.parent_id = d.id
          WHERE child.organization_id = $1
        )
        SELECT 1 FROM descendants WHERE id = $3 LIMIT 1
        """,
        [
          Ecto.UUID.dump!(organization_id),
          Ecto.UUID.dump!(parent_id),
          Ecto.UUID.dump!(possible_descendant_id)
        ]
      )

    rows != []
  end

  defp get_site_group!(scope, id), do: scoped_get!(SiteGroup, scope.organization_id, id)

  defp lock_hierarchy(organization_id) do
    Repo.query!("SELECT pg_advisory_xact_lock(hashtext($1), hashtext($2))", [
      organization_id,
      @hierarchy_lock
    ])
  end

  defp lock_rack!(organization_id, id), do: scoped_lock!(Rack, organization_id, id)
  defp lock_resource!(organization_id, id), do: scoped_lock!(Resource, organization_id, id)

  defp rack_has_placements?(organization_id, rack_id) do
    Enum.any?([DesiredPlacement, CurrentPlacement], fn schema ->
      schema
      |> where(
        [placement],
        placement.organization_id == ^organization_id and placement.rack_id == ^rack_id
      )
      |> Repo.exists?()
    end)
  end

  defp scoped_lock!(schema, organization_id, id) do
    schema
    |> where([record], record.organization_id == ^organization_id and record.id == ^id)
    |> lock("FOR UPDATE")
    |> Repo.one!()
  end

  defp scoped_get!(schema, organization_id, id) do
    schema
    |> where([record], record.organization_id == ^organization_id and record.id == ^id)
    |> Repo.one!()
  end

  defp managed_transaction(%Scope{} = scope, mutation) do
    Repo.transaction(fn ->
      authorize_manager!(scope)

      case mutation.() do
        {:ok, result} -> result
        {:error, reason} -> Repo.rollback(reason)
        result -> result
      end
    end)
  end

  defp reconciliation_transaction(%Scope{} = scope, mutation) do
    Repo.transaction(fn ->
      authorize_reconciler!(scope)

      case mutation.() do
        {:ok, result} -> result
        {:error, reason} -> Repo.rollback(reason)
        result -> result
      end
    end)
  end

  defp authorize_manager!(%Scope{membership_id: membership_id, user: %{id: user_id}} = scope)
       when not is_nil(membership_id) do
    lock_active_organization!(scope.organization_id)

    OrganizationMembership
    |> where([membership], membership.id == ^membership_id)
    |> where([membership], membership.user_id == ^user_id)
    |> where([membership], membership.organization_id == ^scope.organization_id)
    |> where([membership], membership.status == "active")
    |> where([membership], membership.role in ["owner", "admin"])
    |> select([membership], membership.id)
    |> lock("FOR UPDATE")
    |> Repo.one()
    |> case do
      nil -> Repo.rollback(:forbidden)
      _membership_id -> :ok
    end
  end

  defp authorize_manager!(%Scope{}), do: Repo.rollback(:forbidden)

  defp authorize_reconciler!(%Scope{user: nil, roles: roles, organization_id: organization_id}) do
    if "placement_reconciler" in roles do
      lock_active_organization!(organization_id)
    else
      Repo.rollback(:forbidden)
    end
  end

  defp authorize_reconciler!(%Scope{} = scope), do: authorize_manager!(scope)

  defp lock_active_organization!(organization_id) do
    Organization
    |> where([organization], organization.id == ^organization_id)
    |> select([organization], organization.status)
    |> lock("FOR UPDATE")
    |> Repo.one()
    |> case do
      "active" -> :ok
      _inactive_or_missing -> Repo.rollback(:forbidden)
    end
  end

  defp placement_finding_query(organization_id, resource_id, kind) do
    from finding in PlacementFinding,
      where:
        finding.organization_id == ^organization_id and finding.resource_id == ^resource_id and
          finding.kind == ^kind and finding.status == "open"
  end

  defp maybe_where_site(query, nil), do: query

  defp maybe_where_site(query, site_id),
    do: where(query, [location], location.site_id == ^site_id)

  defp attr(attrs, key), do: Map.get(attrs, key) || Map.get(attrs, Atom.to_string(key))

  defp attr_present?(attrs, key),
    do: Map.has_key?(attrs, key) or Map.has_key?(attrs, Atom.to_string(key))

  defp to_integer(value) when is_integer(value), do: value
  defp to_integer(value) when is_binary(value), do: String.to_integer(value)

  defp put_attr(attrs, key, value) do
    if Enum.any?(Map.keys(attrs), &is_atom/1),
      do: Map.put(attrs, key, value),
      else: Map.put(attrs, Atom.to_string(key), value)
  end

  defp insert_or_rollback(changeset) do
    case Repo.insert(changeset) do
      {:ok, record} -> record
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp update_or_rollback(changeset) do
    case Repo.update(changeset) do
      {:ok, record} -> record
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp upsert_or_rollback(%Ecto.Changeset{data: %{id: nil}} = changeset),
    do: insert_or_rollback(changeset)

  defp upsert_or_rollback(changeset), do: update_or_rollback(changeset)
  defp upsert(%Ecto.Changeset{data: %{id: nil}} = changeset), do: Repo.insert(changeset)
  defp upsert(changeset), do: Repo.update(changeset)
end
