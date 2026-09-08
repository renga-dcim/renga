defmodule Renga.Topology do
  @moduledoc """
  Organization-scoped VLAN namespaces and VLAN identity.

  VLAN group range changes and VLAN writes lock the same group row so a
  concurrent mutation cannot strand a VLAN outside its namespace.
  """

  import Ecto.Query, warn: false

  alias Renga.Accounts.Organization
  alias Renga.Accounts.OrganizationMembership
  alias Renga.Accounts.Scope
  alias Renga.Inventory.Interface
  alias Renga.Inventory.Observation
  alias Renga.Inventory.Resource
  alias Renga.Inventory.Source
  alias Renga.Inventory.ResourceStore
  alias Renga.Repo
  alias Renga.Topology.CurrentInterfaceVlanMembership
  alias Renga.Topology.CurrentInterfaceVlanMode
  alias Renga.Topology.DesiredInterfaceVlanAssignment
  alias Renga.Topology.DesiredInterfaceVlanMode
  alias Renga.Topology.InterfaceVlanEvidence
  alias Renga.Topology.InterfaceVlanModeEvidence
  alias Renga.Topology.SourceVlanGroupMapping
  alias Renga.Topology.TopologyFinding
  alias Renga.Topology.Vlan
  alias Renga.Topology.VlanGroup
  alias Renga.Topology.VlanGroupVidRange

  def list_vlan_groups(%Scope{organization_id: organization_id}) do
    VlanGroup
    |> where([group], group.organization_id == ^organization_id)
    |> join(:inner, [group], resource in assoc(group, :resource))
    |> order_by([_group, resource], asc: resource.name)
    |> preload([group, resource],
      resource: resource,
      site: :resource,
      location: :resource,
      vid_ranges: ^vid_ranges_query()
    )
    |> Repo.all()
  end

  def get_vlan_group!(%Scope{organization_id: organization_id}, id) do
    VlanGroup
    |> where([group], group.organization_id == ^organization_id and group.id == ^id)
    |> preload([
      :resource,
      site: :resource,
      location: :resource,
      vid_ranges: ^vid_ranges_query()
    ])
    |> Repo.one!()
  end

  def list_vlans(%Scope{organization_id: organization_id}, vlan_group_id \\ :all) do
    Vlan
    |> where([vlan], vlan.organization_id == ^organization_id)
    |> maybe_where_vlan_group(vlan_group_id)
    |> order_by([vlan], asc: vlan.vid)
    |> preload([:resource, vlan_group: :resource])
    |> Repo.all()
  end

  def get_vlan!(%Scope{organization_id: organization_id}, id) do
    Vlan
    |> where([vlan], vlan.organization_id == ^organization_id and vlan.id == ^id)
    |> preload([:resource, vlan_group: [:resource, vid_ranges: ^vid_ranges_query()]])
    |> Repo.one!()
  end

  def create_vlan_group(%Scope{} = scope, resource_attrs, attrs, ranges)
      when is_list(ranges) do
    managed_transaction(scope, fn ->
      if ranges == [], do: Repo.rollback(:ranges_required)

      resource = create_resource(scope.organization_id, "vlan_group", resource_attrs)

      group =
        %VlanGroup{organization_id: scope.organization_id, resource_id: resource.id}
        |> VlanGroup.changeset(attrs)
        |> insert_or_rollback()

      insert_ranges(scope.organization_id, group.id, ranges)
      get_vlan_group!(scope, group.id)
    end)
  end

  def create_vlan_group(%Scope{} = scope, _resource_attrs, _attrs, _ranges) do
    managed_transaction(scope, fn -> Repo.rollback(:invalid_ranges) end)
  end

  def update_vlan_group(%Scope{} = scope, %VlanGroup{} = group, attrs) do
    managed_transaction(scope, fn ->
      group
      |> then(&scoped_lock!(VlanGroup, scope.organization_id, &1.id))
      |> VlanGroup.changeset(attrs)
      |> update_or_rollback()
      |> then(&get_vlan_group!(scope, &1.id))
    end)
  end

  def replace_vlan_group_ranges(%Scope{} = scope, %VlanGroup{} = group, ranges)
      when is_list(ranges) do
    managed_transaction(scope, fn ->
      if ranges == [], do: Repo.rollback(:ranges_required)
      stored = scoped_lock!(VlanGroup, scope.organization_id, group.id)

      VlanGroupVidRange
      |> where([range], range.organization_id == ^scope.organization_id)
      |> where([range], range.vlan_group_id == ^stored.id)
      |> Repo.delete_all()

      insert_ranges(scope.organization_id, stored.id, ranges)
      ensure_group_vlans_fit!(scope.organization_id, stored.id)
      get_vlan_group!(scope, stored.id)
    end)
  end

  def replace_vlan_group_ranges(%Scope{} = scope, %VlanGroup{}, _ranges) do
    managed_transaction(scope, fn -> Repo.rollback(:invalid_ranges) end)
  end

  def create_vlan(%Scope{} = scope, resource_attrs, attrs) do
    managed_transaction(scope, fn ->
      validation_changeset = vlan_validation_changeset(scope.organization_id, attrs)
      unless validation_changeset.valid?, do: Repo.rollback(validation_changeset)

      group_id = Ecto.Changeset.get_field(validation_changeset, :vlan_group_id)
      vid = Ecto.Changeset.get_field(validation_changeset, :vid)
      name = Ecto.Changeset.get_field(validation_changeset, :name)
      group = lock_vlan_group(scope.organization_id, group_id)
      ensure_vid_allowed!(scope.organization_id, group, vid)

      resource_attrs = vlan_resource_attrs(resource_attrs, group_id, vid, name)
      resource = create_resource(scope.organization_id, "vlan", resource_attrs)

      %Vlan{organization_id: scope.organization_id, resource_id: resource.id}
      |> Vlan.changeset(attrs)
      |> insert_or_rollback()
      |> Repo.preload([:resource, vlan_group: :resource])
    end)
  end

  def update_vlan(%Scope{} = scope, %Vlan{} = vlan, attrs) do
    managed_transaction(scope, fn ->
      current =
        Vlan
        |> where([stored], stored.organization_id == ^scope.organization_id)
        |> where([stored], stored.id == ^vlan.id)
        |> preload(:resource)
        |> Repo.one!()

      changeset = Vlan.changeset(current, attrs)
      unless changeset.valid?, do: Repo.rollback(changeset)
      group_id = Ecto.Changeset.get_field(changeset, :vlan_group_id)

      [current.vlan_group_id, group_id]
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()
      |> Enum.sort()
      |> Enum.each(&lock_vlan_group(scope.organization_id, &1))

      stored =
        Vlan
        |> where([stored], stored.organization_id == ^scope.organization_id)
        |> where([stored], stored.id == ^vlan.id)
        |> lock("FOR UPDATE")
        |> preload(:resource)
        |> Repo.one!()

      changeset = Vlan.changeset(stored, attrs)
      unless changeset.valid?, do: Repo.rollback(changeset)

      group_id = Ecto.Changeset.get_field(changeset, :vlan_group_id)
      vid = Ecto.Changeset.get_field(changeset, :vid)
      name = Ecto.Changeset.get_field(changeset, :name)
      ensure_vid_allowed!(scope.organization_id, group_id, vid)
      update_vlan_resource(stored.resource, group_id, vid, name)

      changeset
      |> update_or_rollback()
      |> Repo.preload([:resource, vlan_group: :resource], force: true)
    end)
  end

  def list_desired_interface_vlan_assignments(
        %Scope{organization_id: organization_id},
        interface_id
      ) do
    DesiredInterfaceVlanAssignment
    |> where([assignment], assignment.organization_id == ^organization_id)
    |> where([assignment], assignment.interface_id == ^interface_id)
    |> order_by([assignment], asc: assignment.tagging_mode, asc: assignment.vlan_id)
    |> preload(:vlan)
    |> Repo.all()
  end

  def list_current_interface_vlan_memberships(
        %Scope{organization_id: organization_id},
        interface_id
      ) do
    CurrentInterfaceVlanMembership
    |> where([membership], membership.organization_id == ^organization_id)
    |> where([membership], membership.interface_id == ^interface_id)
    |> order_by([membership], asc: membership.tagging_mode, asc: membership.vlan_id)
    |> preload([:vlan, :interface_vlan_evidence])
    |> Repo.all()
  end

  def put_desired_interface_vlan_assignment(%Scope{} = scope, interface_id, vlan_id, attrs) do
    managed_transaction(scope, fn ->
      interface = scoped_lock!(Interface, scope.organization_id, interface_id)
      vlan = scoped_get!(Vlan, scope.organization_id, vlan_id)
      tagging_mode = attr(attrs, :tagging_mode)

      validate_mode_membership!(
        DesiredInterfaceVlanMode,
        scope.organization_id,
        interface.id,
        tagging_mode
      )

      DesiredInterfaceVlanAssignment
      |> Repo.get_by(
        organization_id: scope.organization_id,
        interface_id: interface.id,
        vlan_id: vlan.id
      )
      |> case do
        nil ->
          %DesiredInterfaceVlanAssignment{
            organization_id: scope.organization_id,
            interface_id: interface.id,
            vlan_id: vlan.id
          }

        assignment ->
          assignment
      end
      |> DesiredInterfaceVlanAssignment.changeset(attrs)
      |> Repo.insert_or_update()
    end)
  end

  def delete_desired_interface_vlan_assignment(
        %Scope{} = scope,
        %DesiredInterfaceVlanAssignment{} = assignment
      ) do
    managed_transaction(scope, fn ->
      assignment =
        scoped_get!(DesiredInterfaceVlanAssignment, scope.organization_id, assignment.id)

      Repo.delete(assignment)
    end)
  end

  def put_desired_interface_vlan_mode(%Scope{} = scope, interface_id, attrs) do
    managed_transaction(scope, fn ->
      interface = scoped_lock!(Interface, scope.organization_id, interface_id)
      mode = attr(attrs, :mode)

      validate_existing_memberships_for_mode!(
        DesiredInterfaceVlanAssignment,
        scope.organization_id,
        interface.id,
        mode
      )

      upsert_mode(DesiredInterfaceVlanMode, scope.organization_id, interface.id, attrs)
    end)
  end

  def get_desired_interface_vlan_mode(%Scope{organization_id: organization_id}, interface_id) do
    Repo.get_by(DesiredInterfaceVlanMode,
      organization_id: organization_id,
      interface_id: interface_id
    )
  end

  def get_current_interface_vlan_mode(%Scope{organization_id: organization_id}, interface_id) do
    Repo.get_by(CurrentInterfaceVlanMode,
      organization_id: organization_id,
      interface_id: interface_id
    )
  end

  def put_source_vlan_group_mapping(%Scope{} = scope, source_id, vlan_group_id, attrs \\ %{}) do
    managed_transaction(scope, fn ->
      source = scoped_get!(Source, scope.organization_id, source_id)
      group = if vlan_group_id, do: scoped_get!(VlanGroup, scope.organization_id, vlan_group_id)
      source_local_scope = attr(attrs, :source_local_scope) || "default"

      SourceVlanGroupMapping
      |> Repo.get_by(
        organization_id: scope.organization_id,
        source_id: source.id,
        source_local_scope: source_local_scope
      )
      |> case do
        nil ->
          %SourceVlanGroupMapping{
            organization_id: scope.organization_id,
            source_id: source.id
          }

        mapping ->
          mapping
      end
      |> Ecto.Changeset.change(vlan_group_id: group && group.id)
      |> SourceVlanGroupMapping.changeset(
        put_attr(attrs, :source_local_scope, source_local_scope)
      )
      |> Repo.insert_or_update()
    end)
  end

  def list_source_vlan_group_mappings(%Scope{organization_id: organization_id}, source_id) do
    SourceVlanGroupMapping
    |> where(
      [mapping],
      mapping.organization_id == ^organization_id and mapping.source_id == ^source_id
    )
    |> order_by([mapping], asc: mapping.source_local_scope)
    |> Repo.all()
  end

  def list_interface_vlan_evidence(%Scope{organization_id: organization_id}, interface_id) do
    InterfaceVlanEvidence
    |> where(
      [evidence],
      evidence.organization_id == ^organization_id and evidence.interface_id == ^interface_id
    )
    |> order_by([evidence], desc: evidence.observed_at, asc: evidence.source_local_key)
    |> Repo.all()
  end

  def list_interface_vlan_mode_evidence(%Scope{organization_id: organization_id}, interface_id) do
    InterfaceVlanModeEvidence
    |> where([evidence], evidence.organization_id == ^organization_id)
    |> where([evidence], evidence.interface_id == ^interface_id)
    |> order_by([evidence], desc: evidence.observed_at, asc: evidence.observation_id)
    |> Repo.all()
  end

  def list_topology_findings(
        %Scope{organization_id: organization_id},
        interface_id,
        status \\ "open"
      ) do
    TopologyFinding
    |> where([finding], finding.organization_id == ^organization_id)
    |> where([finding], finding.interface_id == ^interface_id and finding.status == ^status)
    |> order_by([finding], asc: finding.kind, asc: finding.resolution_key)
    |> Repo.all()
  end

  @doc false
  def reconcile_interface_vlans(
        %Scope{} = scope,
        %Source{} = source,
        %Observation{} = observation,
        resource_id,
        reported_interfaces,
        current_snapshot?
      ) do
    reconciliation_transaction(scope, fn ->
      source = scoped_get!(Source, scope.organization_id, source.id)
      scoped_get!(Resource, scope.organization_id, resource_id)

      observation =
        Observation
        |> where([item], item.organization_id == ^scope.organization_id)
        |> where([item], item.source_id == ^source.id and item.id == ^observation.id)
        |> Repo.one!()

      interfaces =
        Interface
        |> where([interface], interface.organization_id == ^scope.organization_id)
        |> where([interface], interface.resource_id == ^resource_id)
        |> Repo.all()
        |> Map.new(&{&1.name, &1})

      complete_snapshot? = complete_interface_vlan_snapshot?(source, observation)

      {evidence, observed_keys, mode_interface_ids} =
        reported_interfaces
        |> Enum.reduce({[], [], []}, fn reported, {evidence, keys, mode_ids} ->
          name = reported |> Map.fetch!("name") |> String.trim()

          case Map.fetch(interfaces, name) do
            {:ok, interface} ->
              mode_ids =
                if Map.has_key?(reported, "vlan_mode") do
                  validate_reported_mode!(reported)

                  put_interface_vlan_mode_evidence(
                    scope.organization_id,
                    source,
                    observation,
                    interface,
                    reported["vlan_mode"],
                    complete_snapshot?
                  )

                  [interface.id | mode_ids]
                else
                  mode_ids
                end

              reported_evidence =
                Enum.map(Map.get(reported, "vlans", []), fn membership ->
                  put_interface_vlan_evidence(
                    scope,
                    source,
                    observation,
                    interface,
                    membership,
                    current_snapshot?
                  )
                end)

              {rows, reported_keys} = Enum.unzip(reported_evidence)
              {rows ++ evidence, reported_keys ++ keys, mode_ids}

            :error ->
              {evidence, keys, mode_ids}
          end
        end)

      mode_interface_ids =
        if complete_snapshot? do
          mode_interface_ids ++
            put_omitted_interface_vlan_mode_withdrawals(
              scope.organization_id,
              source,
              observation,
              interfaces,
              reported_interfaces
            )
        else
          mode_interface_ids
        end

      stale_interface_ids =
        if complete_snapshot? do
          stale_omitted_vlan_evidence(
            scope,
            source,
            observation,
            resource_id,
            MapSet.new(observed_keys)
          )
        else
          []
        end

      if current_snapshot? or mode_interface_ids != [] do
        (Enum.map(evidence, & &1.interface_id) ++ stale_interface_ids ++ mode_interface_ids)
        |> Enum.uniq()
        |> Enum.each(fn interface_id ->
          rebuild_current_memberships(scope.organization_id, interface_id)
          rebuild_current_mode(scope.organization_id, interface_id)

          reconcile_interface_findings(
            scope.organization_id,
            interface_id,
            observation.observed_at,
            complete_snapshot?
          )
        end)
      end

      evidence
    end)
  end

  def change_vlan_group(%VlanGroup{} = group, attrs \\ %{}),
    do: VlanGroup.changeset(group, attrs)

  def change_vlan(%Vlan{} = vlan, attrs \\ %{}), do: Vlan.changeset(vlan, attrs)

  defp vlan_validation_changeset(organization_id, attrs) do
    %Vlan{organization_id: organization_id, resource_id: Ecto.UUID.generate()}
    |> Vlan.changeset(attrs)
  end

  defp create_resource(organization_id, kind, attrs) do
    attrs = put_attr(attrs, :kind, kind)

    case ResourceStore.insert(organization_id, attrs) do
      {:ok, resource} -> resource
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp insert_ranges(organization_id, vlan_group_id, ranges) do
    Enum.each(ranges, fn attrs ->
      %VlanGroupVidRange{organization_id: organization_id, vlan_group_id: vlan_group_id}
      |> VlanGroupVidRange.changeset(attrs)
      |> insert_or_rollback()
    end)
  end

  defp ensure_group_vlans_fit!(organization_id, vlan_group_id) do
    outside? =
      Vlan
      |> where([vlan], vlan.organization_id == ^organization_id)
      |> where([vlan], vlan.vlan_group_id == ^vlan_group_id)
      |> where(
        [vlan],
        not exists(
          from range in VlanGroupVidRange,
            where: range.vlan_group_id == parent_as(:vlan).vlan_group_id,
            where: range.start_vid <= parent_as(:vlan).vid,
            where: range.end_vid >= parent_as(:vlan).vid,
            select: 1
        )
      )
      |> from(as: :vlan)
      |> Repo.exists?()

    if outside?, do: Repo.rollback(:vlan_out_of_range)
  end

  defp ensure_vid_allowed!(_organization_id, nil, _vid), do: :ok

  defp ensure_vid_allowed!(organization_id, %VlanGroup{id: group_id}, vid),
    do: ensure_vid_allowed!(organization_id, group_id, vid)

  defp ensure_vid_allowed!(organization_id, group_id, vid) do
    allowed? =
      VlanGroupVidRange
      |> where([range], range.organization_id == ^organization_id)
      |> where([range], range.vlan_group_id == ^group_id)
      |> where([range], range.start_vid <= ^vid and range.end_vid >= ^vid)
      |> Repo.exists?()

    unless allowed?, do: Repo.rollback(:vlan_out_of_range)
  end

  defp put_interface_vlan_evidence(
         scope,
         source,
         observation,
         interface,
         membership,
         current_snapshot?
       ) do
    source_local_scope = Map.get(membership, "scope")
    vid = Map.fetch!(membership, "vid")
    source_local_key = Map.get(membership, "key") || "#{source_local_scope || "default"}:#{vid}"

    {vlan, resolution} =
      resolve_source_vlan(scope.organization_id, source.id, source_local_scope, vid)

    if current_snapshot? do
      InterfaceVlanEvidence
      |> where([evidence], evidence.organization_id == ^scope.organization_id)
      |> where([evidence], evidence.source_id == ^source.id)
      |> where([evidence], evidence.interface_id == ^interface.id)
      |> where([evidence], evidence.source_local_key == ^source_local_key)
      |> where(
        [evidence],
        is_nil(evidence.stale_at) and evidence.observed_at < ^observation.observed_at
      )
      |> Repo.update_all(set: [stale_at: observation.observed_at])
    end

    metadata =
      membership
      |> Map.get("metadata", %{})
      |> Map.put("resolution", resolution)

    evidence =
      %InterfaceVlanEvidence{
        organization_id: scope.organization_id,
        interface_id: interface.id,
        vlan_id: vlan && vlan.id,
        source_id: source.id,
        observation_id: observation.id
      }
      |> InterfaceVlanEvidence.changeset(%{
        source_local_key: source_local_key,
        source_local_scope: source_local_scope,
        vid: vid,
        tagging_mode: membership["tagging_mode"],
        metadata: metadata,
        observed_at: observation.observed_at
      })
      |> insert_or_rollback()

    {evidence, {interface.id, source_local_key}}
  end

  defp resolve_source_vlan(organization_id, source_id, source_local_scope, vid) do
    mappings =
      SourceVlanGroupMapping
      |> where(
        [mapping],
        mapping.organization_id == ^organization_id and mapping.source_id == ^source_id
      )
      |> maybe_where_source_local_scope(source_local_scope)
      |> Repo.all()

    case mappings do
      [] ->
        {nil, "unmapped_scope"}

      [mapping] ->
        resolve_mapped_vlan(organization_id, mapping.vlan_group_id, vid)

      _ambiguous ->
        {nil, "ambiguous_scope"}
    end
  end

  defp resolve_mapped_vlan(organization_id, vlan_group_id, vid) do
    vlan =
      Vlan
      |> where([vlan], vlan.organization_id == ^organization_id)
      |> where([vlan], vlan.vlan_group_id == ^vlan_group_id)
      |> where([vlan], vlan.vid == ^vid)
      |> Repo.one()

    cond do
      vlan ->
        {vlan, "resolved"}

      vlan_group_id && not vid_allowed?(organization_id, vlan_group_id, vid) ->
        {nil, "out_of_range"}

      true ->
        {nil, "unknown_vlan"}
    end
  end

  defp vid_allowed?(organization_id, vlan_group_id, vid) do
    VlanGroupVidRange
    |> where([range], range.organization_id == ^organization_id)
    |> where([range], range.vlan_group_id == ^vlan_group_id)
    |> where([range], range.start_vid <= ^vid and range.end_vid >= ^vid)
    |> Repo.exists?()
  end

  defp stale_omitted_vlan_evidence(scope, source, observation, resource_id, observed_keys) do
    candidates =
      InterfaceVlanEvidence
      |> join(:inner, [evidence], interface in Interface,
        on:
          interface.id == evidence.interface_id and
            interface.organization_id == evidence.organization_id
      )
      |> where([evidence, interface], evidence.organization_id == ^scope.organization_id)
      |> where([evidence, _interface], evidence.source_id == ^source.id)
      |> where([evidence, _interface], is_nil(evidence.stale_at))
      |> where([evidence, _interface], evidence.observed_at < ^observation.observed_at)
      |> where([_evidence, interface], interface.resource_id == ^resource_id)
      |> Repo.all()

    candidates
    |> Enum.reject(&MapSet.member?(observed_keys, {&1.interface_id, &1.source_local_key}))
    |> Enum.each(fn evidence ->
      evidence
      |> Ecto.Changeset.change(stale_at: observation.observed_at)
      |> update_or_rollback()
    end)

    Enum.map(candidates, & &1.interface_id)
  end

  defp put_omitted_interface_vlan_mode_withdrawals(
         organization_id,
         source,
         observation,
         interfaces,
         reported_interfaces
       ) do
    reported_mode_names =
      reported_interfaces
      |> Enum.filter(&Map.has_key?(&1, "vlan_mode"))
      |> MapSet.new(&(&1 |> Map.fetch!("name") |> String.trim()))

    interfaces
    |> Enum.reject(fn {name, _interface} -> MapSet.member?(reported_mode_names, name) end)
    |> Enum.map(fn {_name, interface} ->
      put_interface_vlan_mode_evidence(
        organization_id,
        source,
        observation,
        interface,
        nil,
        true
      )

      interface.id
    end)
  end

  defp put_interface_vlan_mode_evidence(
         organization_id,
         source,
         observation,
         interface,
         mode,
         complete_snapshot?
       ) do
    existing =
      Repo.get_by(InterfaceVlanModeEvidence,
        organization_id: organization_id,
        observation_id: observation.id,
        interface_id: interface.id
      )

    unless existing do
      %InterfaceVlanModeEvidence{
        organization_id: organization_id,
        interface_id: interface.id,
        source_id: source.id,
        observation_id: observation.id
      }
      |> InterfaceVlanModeEvidence.changeset(%{
        mode: mode,
        observed_at: observation.observed_at,
        metadata: %{
          "complete_snapshot" => complete_snapshot?,
          "withdrawal" => is_nil(mode)
        }
      })
      |> insert_or_rollback()
    end
  end

  defp rebuild_current_memberships(organization_id, interface_id) do
    scoped_lock!(Interface, organization_id, interface_id)

    latest_complete_by_source =
      InterfaceVlanModeEvidence
      |> where([item], item.organization_id == ^organization_id)
      |> where([item], item.interface_id == ^interface_id)
      |> where([item], fragment("?->>'complete_snapshot' = 'true'", item.metadata))
      |> Repo.all()
      |> Enum.group_by(& &1.source_id)
      |> Map.new(fn {source_id, evidence} ->
        {source_id, Enum.max_by(evidence, &observation_order/1)}
      end)

    selected =
      InterfaceVlanEvidence
      |> where([evidence], evidence.organization_id == ^organization_id)
      |> where([evidence], evidence.interface_id == ^interface_id)
      |> where([evidence], is_nil(evidence.stale_at) and not is_nil(evidence.vlan_id))
      |> Repo.all()
      |> latest_source_membership_evidence()
      |> Enum.filter(&membership_after_latest_complete_snapshot?(latest_complete_by_source, &1))
      |> Enum.group_by(& &1.vlan_id)
      |> Enum.map(fn {_vlan_id, evidence} -> Enum.max_by(evidence, &observation_order/1) end)
      |> select_effective_untagged()

    CurrentInterfaceVlanMembership
    |> where([membership], membership.organization_id == ^organization_id)
    |> where([membership], membership.interface_id == ^interface_id)
    |> Repo.delete_all()

    Enum.each(selected, fn evidence ->
      %CurrentInterfaceVlanMembership{
        organization_id: organization_id,
        interface_id: interface_id,
        vlan_id: evidence.vlan_id,
        interface_vlan_evidence_id: evidence.id
      }
      |> CurrentInterfaceVlanMembership.changeset(%{
        tagging_mode: evidence.tagging_mode,
        metadata: %{"source_id" => evidence.source_id}
      })
      |> insert_or_rollback()
    end)
  end

  defp rebuild_current_mode(organization_id, interface_id) do
    evidence = effective_mode_evidence(organization_id, interface_id)

    current =
      Repo.get_by(CurrentInterfaceVlanMode,
        organization_id: organization_id,
        interface_id: interface_id
      )

    memberships =
      CurrentInterfaceVlanMembership
      |> where([membership], membership.organization_id == ^organization_id)
      |> where([membership], membership.interface_id == ^interface_id)
      |> Repo.all()

    cond do
      evidence && mode_compatible?(evidence.mode, memberships) ->
        mode =
          current ||
            %CurrentInterfaceVlanMode{
              organization_id: organization_id,
              interface_id: interface_id
            }

        mode
        |> Ecto.Changeset.change(interface_vlan_mode_evidence_id: evidence.id)
        |> CurrentInterfaceVlanMode.changeset(%{
          mode: evidence.mode,
          metadata: %{"source_id" => evidence.source_id}
        })
        |> Repo.insert_or_update()
        |> case do
          {:ok, mode} -> mode
          {:error, reason} -> Repo.rollback(reason)
        end

      current ->
        Repo.delete!(current)

      true ->
        nil
    end
  end

  defp effective_mode_evidence(organization_id, interface_id) do
    InterfaceVlanModeEvidence
    |> where([evidence], evidence.organization_id == ^organization_id)
    |> where([evidence], evidence.interface_id == ^interface_id)
    |> Repo.all()
    |> Enum.group_by(& &1.source_id)
    |> Enum.map(fn {_source_id, evidence} ->
      Enum.max_by(evidence, &observation_order/1)
    end)
    |> Enum.reject(&is_nil(&1.mode))
    |> Enum.max_by(&observation_order/1, fn -> nil end)
  end

  defp latest_source_membership_evidence(evidence) do
    evidence
    |> Enum.group_by(&{&1.source_id, &1.source_local_key})
    |> Enum.map(fn {_key, items} -> Enum.max_by(items, &observation_order/1) end)
  end

  defp membership_after_latest_complete_snapshot?(latest_complete_by_source, evidence) do
    latest_complete = Map.get(latest_complete_by_source, evidence.source_id)
    is_nil(latest_complete) or observation_order(evidence) >= observation_order(latest_complete)
  end

  defp observation_order(evidence) do
    {DateTime.to_unix(evidence.observed_at, :microsecond), evidence.observation_id}
  end

  defp mode_compatible?("access", memberships),
    do: Enum.all?(memberships, &(&1.tagging_mode == "untagged"))

  defp mode_compatible?(_mode, _memberships), do: true

  defp select_effective_untagged(evidence) do
    {untagged, tagged} = Enum.split_with(evidence, &(&1.tagging_mode == "untagged"))

    case untagged do
      [] -> tagged
      memberships -> [Enum.max_by(memberships, &observation_order/1) | tagged]
    end
  end

  defp reconcile_interface_findings(
         organization_id,
         interface_id,
         observed_at,
         complete_snapshot?
       ) do
    evidence =
      InterfaceVlanEvidence
      |> where([item], item.organization_id == ^organization_id)
      |> where([item], item.interface_id == ^interface_id and is_nil(item.stale_at))
      |> Repo.all()

    desired =
      DesiredInterfaceVlanAssignment
      |> where(
        [item],
        item.organization_id == ^organization_id and item.interface_id == ^interface_id
      )
      |> Repo.all()

    current =
      CurrentInterfaceVlanMembership
      |> where(
        [item],
        item.organization_id == ^organization_id and item.interface_id == ^interface_id
      )
      |> Repo.all()

    findings =
      unresolved_vlan_findings(evidence, observed_at) ++
        evidence_conflict_findings(evidence, observed_at) ++
        drift_findings(desired, current, observed_at, complete_snapshot?) ++
        mode_conflict_findings(organization_id, interface_id, current, observed_at)

    keys = MapSet.new(findings, &{&1.kind, &1.resolution_key})
    Enum.each(findings, &put_topology_finding(organization_id, interface_id, &1))

    TopologyFinding
    |> where([finding], finding.organization_id == ^organization_id)
    |> where([finding], finding.interface_id == ^interface_id and finding.status == "open")
    |> where([finding], finding.last_observed_at <= ^observed_at)
    |> Repo.all()
    |> Enum.reject(&MapSet.member?(keys, {&1.kind, &1.resolution_key}))
    |> Enum.reject(&(&1.kind == "missing_vlan" and not complete_snapshot?))
    |> Enum.each(fn finding ->
      finding
      |> TopologyFinding.changeset(%{status: "resolved", resolved_at: observed_at})
      |> update_or_rollback()
    end)
  end

  defp unresolved_vlan_findings(evidence, observed_at) do
    evidence
    |> Enum.reject(&(&1.metadata["resolution"] == "resolved"))
    |> Enum.map(fn item ->
      resolution = item.metadata["resolution"] || "unknown_vlan"

      %{
        kind: resolution_finding_kind(resolution),
        resolution_key: "#{item.source_id}:#{item.source_local_key}",
        message: resolution_finding_message(resolution, item.vid),
        details: %{
          "source_id" => item.source_id,
          "source_local_key" => item.source_local_key,
          "source_local_scope" => item.source_local_scope,
          "vid" => item.vid
        },
        last_observed_at: observed_at
      }
    end)
  end

  defp evidence_conflict_findings(evidence, observed_at) do
    tagging_conflicts =
      evidence
      |> Enum.reject(&is_nil(&1.vlan_id))
      |> Enum.group_by(& &1.vlan_id)
      |> Enum.filter(fn {_vlan_id, items} ->
        items |> Enum.map(& &1.tagging_mode) |> Enum.uniq() |> length() > 1
      end)
      |> Enum.map(fn {vlan_id, _items} ->
        %{
          kind: "conflicting_tagging_mode",
          resolution_key: "evidence:#{vlan_id}",
          message: "Sources report conflicting tagging modes for VLAN #{vlan_id}",
          details: %{"vlan_id" => vlan_id},
          last_observed_at: observed_at
        }
      end)

    untagged_vlans =
      evidence
      |> Enum.filter(&(&1.tagging_mode == "untagged" and not is_nil(&1.vlan_id)))
      |> Enum.map(& &1.vlan_id)
      |> Enum.uniq()

    if length(untagged_vlans) > 1 do
      [
        %{
          kind: "conflicting_untagged_vlan",
          resolution_key: "effective_untagged",
          message: "Sources report more than one effective untagged VLAN",
          details: %{"vlan_ids" => untagged_vlans},
          last_observed_at: observed_at
        }
        | tagging_conflicts
      ]
    else
      tagging_conflicts
    end
  end

  defp drift_findings(desired, current, observed_at, complete_snapshot?) do
    desired_by_vlan = Map.new(desired, &{&1.vlan_id, &1})
    current_by_vlan = Map.new(current, &{&1.vlan_id, &1})

    observed_findings =
      Enum.flat_map(current_by_vlan, fn {vlan_id, membership} ->
        case Map.get(desired_by_vlan, vlan_id) do
          nil ->
            [
              drift_finding(
                "unexpected_vlan",
                vlan_id,
                "Observed VLAN is not desired",
                observed_at
              )
            ]

          %{tagging_mode: desired_mode} when desired_mode != membership.tagging_mode ->
            [
              drift_finding(
                "conflicting_tagging_mode",
                vlan_id,
                "Desired and current VLAN tagging modes differ",
                observed_at
              )
            ]

          _matching ->
            []
        end
      end)

    if complete_snapshot? do
      missing =
        desired_by_vlan
        |> Map.keys()
        |> Enum.reject(&Map.has_key?(current_by_vlan, &1))
        |> Enum.map(
          &drift_finding("missing_vlan", &1, "Desired VLAN is not observed", observed_at)
        )

      observed_findings ++ missing
    else
      observed_findings
    end
  end

  defp mode_conflict_findings(organization_id, interface_id, memberships, observed_at) do
    case effective_mode_evidence(organization_id, interface_id) do
      nil ->
        []

      evidence ->
        if mode_compatible?(evidence.mode, memberships) do
          []
        else
          [
            %{
              kind: "conflicting_interface_mode",
              resolution_key: "effective_mode",
              message: "Observed interface mode conflicts with current VLAN membership",
              details: %{"mode" => evidence.mode, "source_id" => evidence.source_id},
              last_observed_at: observed_at
            }
          ]
        end
    end
  end

  defp drift_finding(kind, vlan_id, message, observed_at) do
    %{
      kind: kind,
      resolution_key: "drift:#{vlan_id}",
      message: message,
      details: %{"vlan_id" => vlan_id},
      last_observed_at: observed_at
    }
  end

  defp put_topology_finding(organization_id, interface_id, attrs) do
    TopologyFinding
    |> Repo.get_by(
      organization_id: organization_id,
      interface_id: interface_id,
      kind: attrs.kind,
      resolution_key: attrs.resolution_key,
      status: "open"
    )
    |> case do
      nil -> %TopologyFinding{organization_id: organization_id, interface_id: interface_id}
      finding -> finding
    end
    |> TopologyFinding.changeset(Map.merge(attrs, %{status: "open", resolved_at: nil}))
    |> Repo.insert_or_update()
    |> case do
      {:ok, finding} -> finding
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp resolution_finding_kind("ambiguous_scope"), do: "ambiguous_scope"
  defp resolution_finding_kind("out_of_range"), do: "out_of_range_vid"
  defp resolution_finding_kind(_resolution), do: "unknown_vlan"

  defp resolution_finding_message("ambiguous_scope", vid),
    do: "VLAN #{vid} has an ambiguous source-local scope"

  defp resolution_finding_message("out_of_range", vid),
    do: "VLAN #{vid} is outside the mapped group's valid range"

  defp resolution_finding_message(_resolution, vid),
    do: "VLAN #{vid} cannot be resolved in a mapped namespace"

  defp complete_interface_vlan_snapshot?(source, observation) do
    source.metadata["interface_vlan_snapshot_policy"] == "complete" and
      get_in(observation.payload, ["section_completeness", "interface_vlans"]) == true
  end

  defp validate_reported_mode!(reported) do
    mode = reported["vlan_mode"]
    memberships = Map.get(reported, "vlans", [])

    if mode == "access" and Enum.any?(memberships, &(&1["tagging_mode"] != "untagged")),
      do: Repo.rollback(:invalid_interface_vlan_mode)
  end

  defp validate_mode_membership!(schema, organization_id, interface_id, tagging_mode) do
    case Repo.get_by(schema, organization_id: organization_id, interface_id: interface_id) do
      %{mode: "access"} when tagging_mode != "untagged" ->
        Repo.rollback(:invalid_interface_vlan_mode)

      _mode ->
        :ok
    end
  end

  defp validate_existing_memberships_for_mode!(schema, organization_id, interface_id, "access") do
    if Repo.exists?(
         from membership in schema,
           where:
             membership.organization_id == ^organization_id and
               membership.interface_id == ^interface_id and membership.tagging_mode != "untagged"
       ),
       do: Repo.rollback(:invalid_interface_vlan_mode)
  end

  defp validate_existing_memberships_for_mode!(_schema, _organization_id, _interface_id, _mode),
    do: :ok

  defp upsert_mode(schema, organization_id, interface_id, attrs) do
    schema
    |> Repo.get_by(organization_id: organization_id, interface_id: interface_id)
    |> case do
      nil -> struct(schema, organization_id: organization_id, interface_id: interface_id)
      mode -> mode
    end
    |> schema.changeset(attrs)
    |> Repo.insert_or_update()
  end

  defp maybe_where_source_local_scope(query, nil), do: query

  defp maybe_where_source_local_scope(query, scope),
    do: where(query, [mapping], mapping.source_local_scope == ^scope)

  defp lock_vlan_group(_organization_id, nil), do: nil

  defp lock_vlan_group(organization_id, id) do
    VlanGroup
    |> where([group], group.organization_id == ^organization_id and group.id == ^id)
    |> lock("FOR UPDATE")
    |> Repo.one()
    |> case do
      nil -> Repo.rollback(:vlan_group_not_found)
      group -> group
    end
  end

  defp update_vlan_resource(resource, group_id, vid, name) do
    resource_name = vlan_resource_name(group_id, vid)

    if resource.name != resource_name or resource.display_name != name do
      case ResourceStore.update(resource, %{name: resource_name, display_name: name}) do
        {:ok, _resource} -> :ok
        {:error, reason} -> Repo.rollback(reason)
      end
    end
  end

  defp vlan_resource_attrs(attrs, group_id, vid, name) do
    attrs
    |> put_attr(:name, vlan_resource_name(group_id, vid))
    |> put_attr(:display_name, name)
    |> put_default_attr(:lifecycle_state, "active")
  end

  defp vlan_resource_name(nil, vid), do: "global/#{vid}"
  defp vlan_resource_name(group_id, vid), do: "#{group_id}/#{vid}"

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
    if "topology_reconciler" in roles do
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

  defp insert_or_rollback(changeset) do
    case Repo.insert(changeset) do
      {:ok, result} -> result
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp update_or_rollback(changeset) do
    case Repo.update(changeset) do
      {:ok, result} -> result
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp vid_ranges_query,
    do: from(range in VlanGroupVidRange, order_by: [asc: range.start_vid, asc: range.end_vid])

  defp maybe_where_vlan_group(query, :all), do: query
  defp maybe_where_vlan_group(query, nil), do: where(query, [vlan], is_nil(vlan.vlan_group_id))

  defp maybe_where_vlan_group(query, vlan_group_id),
    do: where(query, [vlan], vlan.vlan_group_id == ^vlan_group_id)

  defp attr(attrs, key), do: Map.get(attrs, key) || Map.get(attrs, Atom.to_string(key))

  defp put_default_attr(attrs, key, value) do
    if attr(attrs, key), do: attrs, else: put_attr(attrs, key, value)
  end

  defp put_attr(attrs, key, value) do
    if Enum.any?(Map.keys(attrs), &is_atom/1),
      do: Map.put(attrs, key, value),
      else: Map.put(attrs, Atom.to_string(key), value)
  end
end
