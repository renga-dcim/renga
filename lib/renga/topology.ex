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
  alias Renga.Inventory.ResourceStore
  alias Renga.Repo
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
