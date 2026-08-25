defmodule Renga.Catalog do
  @moduledoc """
  Organization-scoped reusable hardware definitions.

  Catalog types have resource envelopes, while immutable subordinate revisions
  snapshot typed specifications and expected component templates. Assigning a
  type to an asset is deliberately outside this context so catalog expectations
  cannot be mistaken for observed hardware.
  """

  import Ecto.Query, warn: false

  alias Renga.Accounts.Organization
  alias Renga.Accounts.OrganizationMembership
  alias Renga.Accounts.Scope
  alias Renga.Catalog.ComponentTemplate
  alias Renga.Catalog.ExpectedComponent
  alias Renga.Catalog.ExpectedComponentException
  alias Renga.Catalog.HardwareAssignment
  alias Renga.Catalog.HardwareMatchFinding
  alias Renga.Catalog.HardwareType
  alias Renga.Catalog.InventoryItem
  alias Renga.Catalog.Manufacturer
  alias Renga.Catalog.Module
  alias Renga.Catalog.ModuleBay
  alias Renga.Catalog.ModuleBayCompatibleType
  alias Renga.Catalog.ModuleType
  alias Renga.Catalog.TypeRevision
  alias Renga.Inventory
  alias Renga.Inventory.Host
  alias Renga.Inventory.Resource
  alias Renga.Repo

  @physical_device_kinds ~w(server switch pdu storage)
  @inventory_item_hierarchy_lock "catalog-inventory-item-hierarchy"

  def list_manufacturers(%Scope{organization_id: organization_id}) do
    Manufacturer
    |> where([manufacturer], manufacturer.organization_id == ^organization_id)
    |> join(:inner, [manufacturer], resource in assoc(manufacturer, :resource))
    |> order_by([_manufacturer, resource], asc: resource.name)
    |> preload([manufacturer, resource], resource: resource)
    |> Repo.all()
  end

  def get_manufacturer!(%Scope{organization_id: organization_id}, id) do
    Manufacturer
    |> where([manufacturer], manufacturer.organization_id == ^organization_id)
    |> Repo.get!(id)
    |> Repo.preload(:resource)
  end

  def list_hardware_types(%Scope{organization_id: organization_id}) do
    HardwareType
    |> where([hardware_type], hardware_type.organization_id == ^organization_id)
    |> join(:inner, [hardware_type], resource in assoc(hardware_type, :resource))
    |> order_by([hardware_type, resource], asc: resource.name, asc: hardware_type.model)
    |> preload([hardware_type, resource],
      resource: resource,
      manufacturer: :resource
    )
    |> Repo.all()
  end

  def get_hardware_type!(%Scope{organization_id: organization_id}, id) do
    HardwareType
    |> where([hardware_type], hardware_type.organization_id == ^organization_id)
    |> Repo.get!(id)
    |> preload_type()
  end

  def list_module_types(%Scope{organization_id: organization_id}) do
    ModuleType
    |> where([module_type], module_type.organization_id == ^organization_id)
    |> join(:inner, [module_type], resource in assoc(module_type, :resource))
    |> order_by([module_type, resource], asc: resource.name, asc: module_type.model)
    |> preload([module_type, resource],
      resource: resource,
      manufacturer: :resource
    )
    |> Repo.all()
  end

  def get_module_type!(%Scope{organization_id: organization_id}, id) do
    ModuleType
    |> where([module_type], module_type.organization_id == ^organization_id)
    |> Repo.get!(id)
    |> preload_type()
  end

  def list_modules(%Scope{organization_id: organization_id}) do
    Module
    |> where([module], module.organization_id == ^organization_id)
    |> join(:inner, [module], resource in assoc(module, :resource))
    |> order_by([_module, resource], asc: resource.name)
    |> preload([module, resource], resource: resource, module_type: [:resource, :manufacturer])
    |> Repo.all()
  end

  def get_module!(%Scope{organization_id: organization_id}, id) do
    Module
    |> where([module], module.organization_id == ^organization_id and module.id == ^id)
    |> preload([:resource, :catalog_type_revision, module_type: [:resource, :manufacturer]])
    |> Repo.one!()
  end

  def list_module_bays(%Scope{organization_id: organization_id}, owner_resource_id) do
    ModuleBay
    |> where(
      [bay],
      bay.organization_id == ^organization_id and bay.owner_resource_id == ^owner_resource_id
    )
    |> order_by([bay], asc: bay.name)
    |> preload([:owner_resource, compatible_module_types: [:resource, :manufacturer]])
    |> Repo.all()
  end

  def get_module_bay!(%Scope{organization_id: organization_id}, id) do
    ModuleBay
    |> where([bay], bay.organization_id == ^organization_id and bay.id == ^id)
    |> preload([:owner_resource, compatible_module_types: [:resource, :manufacturer]])
    |> Repo.one!()
  end

  def get_hardware_assignment(%Scope{organization_id: organization_id}, resource_id) do
    HardwareAssignment
    |> where(
      [assignment],
      assignment.organization_id == ^organization_id and assignment.resource_id == ^resource_id
    )
    |> preload([:hardware_type, :catalog_type_revision])
    |> Repo.one()
  end

  def list_hardware_match_findings(
        %Scope{organization_id: organization_id},
        status \\ "open"
      ) do
    HardwareMatchFinding
    |> where([finding], finding.organization_id == ^organization_id and finding.status == ^status)
    |> order_by([finding], desc: finding.inserted_at)
    |> Repo.all()
  end

  def list_expected_components(%Scope{organization_id: organization_id}, resource_id) do
    ExpectedComponent
    |> join(:inner, [component], assignment in assoc(component, :hardware_assignment))
    |> where(
      [component, assignment],
      component.organization_id == ^organization_id and assignment.resource_id == ^resource_id
    )
    |> order_by([component], asc: component.kind, asc: component.name)
    |> Repo.all()
  end

  def list_inventory_items(%Scope{organization_id: organization_id}, owner_resource_id) do
    InventoryItem
    |> where(
      [item],
      item.organization_id == ^organization_id and item.owner_resource_id == ^owner_resource_id
    )
    |> order_by([item], asc: item.name)
    |> preload([:parent])
    |> Repo.all()
  end

  def get_inventory_item!(%Scope{organization_id: organization_id}, id) do
    InventoryItem
    |> where([item], item.organization_id == ^organization_id and item.id == ^id)
    |> preload([:parent, :children])
    |> Repo.one!()
  end

  def create_manufacturer(%Scope{} = scope, resource_attrs, attrs) do
    managed_transaction(scope, fn ->
      create_projection(scope, Manufacturer, "manufacturer", resource_attrs, attrs)
    end)
  end

  def create_hardware_type(%Scope{} = scope, resource_attrs, attrs) do
    managed_transaction(scope, fn ->
      create_projection(scope, HardwareType, "hardware_type", resource_attrs, attrs)
    end)
  end

  def create_module_type(%Scope{} = scope, resource_attrs, attrs) do
    managed_transaction(scope, fn ->
      create_projection(scope, ModuleType, "module_type", resource_attrs, attrs)
    end)
  end

  def create_hardware_type_revision(
        %Scope{} = scope,
        %HardwareType{} = hardware_type,
        attrs,
        templates \\ []
      ) do
    create_type_revision(scope, HardwareType, hardware_type.id, attrs, templates)
  end

  def create_module_type_revision(
        %Scope{} = scope,
        %ModuleType{} = module_type,
        attrs,
        templates \\ []
      ) do
    create_type_revision(scope, ModuleType, module_type.id, attrs, templates)
  end

  def create_module(%Scope{} = scope, %ModuleType{} = module_type, resource_attrs, attrs \\ %{}) do
    managed_transaction(scope, fn ->
      stored_type = scoped_lock!(ModuleType, scope.organization_id, module_type.id)
      revision = latest_module_revision!(scope.organization_id, stored_type.id)

      resource =
        case Inventory.create_resource(scope, put_attr(resource_attrs, :kind, "module")) do
          {:ok, resource} -> resource
          {:error, reason} -> Repo.rollback(reason)
        end

      %Module{
        organization_id: scope.organization_id,
        resource_id: resource.id,
        module_type_id: stored_type.id,
        catalog_type_revision_id: revision.id
      }
      |> Module.changeset(attrs)
      |> insert_or_rollback()
      |> Repo.preload([:resource, :catalog_type_revision, module_type: :resource])
    end)
  end

  def create_module_bay(
        %Scope{} = scope,
        owner_resource_id,
        attrs,
        compatible_module_type_ids \\ []
      ) do
    managed_transaction(scope, fn ->
      owner = scoped_module_bay_owner!(scope.organization_id, owner_resource_id)
      module_types = scoped_module_types!(scope.organization_id, compatible_module_type_ids)

      bay =
        %ModuleBay{
          organization_id: scope.organization_id,
          owner_resource_id: owner.id,
          owner_kind: owner.kind
        }
        |> ModuleBay.changeset(attrs)
        |> insert_or_rollback()

      replace_module_bay_compatibility(scope, bay, module_types)
      get_module_bay!(scope, bay.id)
    end)
  end

  def update_module_bay(%Scope{} = scope, %ModuleBay{} = bay, attrs) do
    managed_transaction(scope, fn ->
      stored = scoped_lock!(ModuleBay, scope.organization_id, bay.id)
      stored |> ModuleBay.changeset(attrs) |> update_or_rollback()
    end)
  end

  def set_module_bay_compatible_types(%Scope{} = scope, %ModuleBay{} = bay, module_type_ids) do
    managed_transaction(scope, fn ->
      stored = scoped_lock!(ModuleBay, scope.organization_id, bay.id)
      module_types = scoped_module_types!(scope.organization_id, module_type_ids)
      replace_module_bay_compatibility(scope, stored, module_types)
      get_module_bay!(scope, stored.id)
    end)
  end

  def create_inventory_item(%Scope{} = scope, owner_resource_id, attrs) do
    managed_transaction(scope, fn ->
      lock_inventory_item_hierarchy(scope.organization_id)
      owner = scoped_physical_resource!(scope.organization_id, owner_resource_id)

      changeset =
        %InventoryItem{
          organization_id: scope.organization_id,
          owner_resource_id: owner.id
        }
        |> InventoryItem.changeset(attrs)

      parent_id = Ecto.Changeset.get_field(changeset, :parent_id)
      validate_inventory_item_parent!(scope, nil, owner.id, parent_id)
      insert_or_rollback(changeset)
    end)
  end

  def update_inventory_item(%Scope{} = scope, %InventoryItem{} = item, attrs) do
    managed_transaction(scope, fn ->
      lock_inventory_item_hierarchy(scope.organization_id)
      stored = scoped_lock!(InventoryItem, scope.organization_id, item.id)
      changeset = InventoryItem.changeset(stored, attrs)
      parent_id = Ecto.Changeset.get_field(changeset, :parent_id)
      validate_inventory_item_parent!(scope, stored.id, stored.owner_resource_id, parent_id)
      update_or_rollback(changeset)
    end)
  end

  @doc """
  Assigns the latest finalized catalog revision to a physical resource.

  The selected revision remains pinned until an operator changes the assignment;
  publishing a newer catalog revision never rewrites an existing asset.
  """
  def assign_hardware_type(%Scope{} = scope, resource_id, hardware_type_id) do
    managed_transaction(scope, fn ->
      resource = lock_physical_resource!(scope, resource_id)
      hardware_type = scoped_lock!(HardwareType, scope.organization_id, hardware_type_id)
      revision = latest_hardware_revision!(scope.organization_id, hardware_type.id)

      assignment =
        put_hardware_assignment(scope, resource, hardware_type, revision, "operator", %{
          "user_id" => scope.user.id
        })

      resolve_match_finding(scope, resource.id)
      materialize_expected_components(scope, assignment)
      assignment
    end)
  end

  def clear_hardware_assignment(%Scope{} = scope, resource_id) do
    managed_transaction(scope, fn ->
      resource = lock_physical_resource!(scope, resource_id)

      HardwareAssignment
      |> where(
        [assignment],
        assignment.organization_id == ^scope.organization_id and
          assignment.resource_id == ^resource.id
      )
      |> Repo.delete_all()

      nil
    end)
  end

  @doc """
  Matches canonical host manufacturer/model facts without guessing on ambiguity.

  Operator assignments always win. Reconciled assignments retain the exact
  catalog revision and the host field ownership metadata used for the decision.
  """
  def reconcile_hardware_type(%Scope{} = scope, resource_id) do
    reconciliation_transaction(scope, fn ->
      resource = lock_physical_resource!(scope, resource_id)
      assignment = locked_assignment(scope.organization_id, resource.id)

      if assignment && assignment.origin == "operator" do
        assignment
      else
        reconcile_unconfirmed_hardware_type(scope, resource, assignment)
      end
    end)
  end

  @doc """
  Adds or replaces a confirmed per-asset exception and rematerializes expectations.

  Suppress and alter exceptions must target a template in the assignment's pinned
  revision. Add exceptions describe a local component without changing a template.
  """
  def put_expected_component_exception(%Scope{} = scope, resource_id, attrs) do
    managed_transaction(scope, fn ->
      resource = lock_physical_resource!(scope, resource_id)
      assignment = locked_assignment(scope.organization_id, resource.id)
      if is_nil(assignment), do: Repo.rollback(:hardware_type_not_assigned)

      exception =
        find_expected_component_exception(scope, assignment, attrs) ||
          %ExpectedComponentException{
            organization_id: scope.organization_id,
            hardware_assignment_id: assignment.id,
            catalog_type_revision_id: assignment.catalog_type_revision_id
          }

      template_id = attr(attrs, :component_template_id) || exception.component_template_id
      validate_exception_template!(scope, assignment, template_id, attr(attrs, :action))

      exception =
        %{
          exception
          | catalog_type_revision_id: assignment.catalog_type_revision_id,
            confirmed_by_user_id: scope.user.id
        }
        |> ExpectedComponentException.changeset(attrs)
        |> upsert()

      materialize_expected_components(scope, assignment)
      exception
    end)
  end

  def delete_expected_component_exception(%Scope{} = scope, resource_id, exception_id) do
    managed_transaction(scope, fn ->
      resource = lock_physical_resource!(scope, resource_id)
      assignment = locked_assignment(scope.organization_id, resource.id)
      if is_nil(assignment), do: Repo.rollback(:hardware_type_not_assigned)

      exception =
        ExpectedComponentException
        |> where(
          [exception],
          exception.id == ^exception_id and exception.organization_id == ^scope.organization_id and
            exception.hardware_assignment_id == ^assignment.id
        )
        |> Repo.one!()

      ExpectedComponent
      |> where(
        [component],
        component.organization_id == ^scope.organization_id and
          component.exception_id == ^exception.id
      )
      |> Repo.delete_all()

      Repo.delete!(exception)
      materialize_expected_components(scope, assignment)
      nil
    end)
  end

  def change_manufacturer(%Manufacturer{} = manufacturer, attrs \\ %{}),
    do: Manufacturer.changeset(manufacturer, attrs)

  def change_hardware_type(%HardwareType{} = hardware_type, attrs \\ %{}),
    do: HardwareType.changeset(hardware_type, attrs)

  def change_module_type(%ModuleType{} = module_type, attrs \\ %{}),
    do: ModuleType.changeset(module_type, attrs)

  defp create_type_revision(scope, schema, type_id, attrs, templates)
       when is_list(templates) do
    managed_transaction(scope, fn ->
      type = scoped_lock!(schema, scope.organization_id, type_id)
      owner_field = owner_field(schema)

      revision =
        %TypeRevision{organization_id: scope.organization_id}
        |> Ecto.Changeset.change(%{
          owner_field => type.id,
          revision: next_revision(scope.organization_id, owner_field, type.id)
        })
        |> TypeRevision.changeset(attrs)
        |> insert_or_rollback()

      Enum.each(templates, fn template_attrs ->
        %ComponentTemplate{
          organization_id: scope.organization_id,
          catalog_type_revision_id: revision.id
        }
        |> ComponentTemplate.changeset(template_attrs)
        |> insert_or_rollback()
      end)

      finalized_at = Renga.Time.utc_now_ms()

      {1, _} =
        TypeRevision
        |> where([stored], stored.id == ^revision.id and is_nil(stored.finalized_at))
        |> Repo.update_all(set: [finalized_at: finalized_at])

      revision = %{revision | finalized_at: finalized_at}

      Repo.preload(revision,
        component_templates: from(template in ComponentTemplate, order_by: template.name)
      )
    end)
  end

  defp create_type_revision(scope, _schema, _type_id, _attrs, _templates),
    do: managed_transaction(scope, fn -> Repo.rollback(:invalid_templates) end)

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

  defp preload_type(type) do
    revisions =
      from revision in TypeRevision,
        order_by: [desc: revision.revision],
        preload: [
          component_templates: ^from(template in ComponentTemplate, order_by: template.name)
        ]

    Repo.preload(type, [:resource, manufacturer: :resource, revisions: revisions])
  end

  defp lock_physical_resource!(scope, resource_id) do
    resource = scoped_lock!(Resource, scope.organization_id, resource_id)

    if resource.kind in @physical_device_kinds,
      do: resource,
      else: Repo.rollback(:unsupported_resource_kind)
  end

  defp scoped_physical_resource!(organization_id, resource_id) do
    resource = scoped_get!(Resource, organization_id, resource_id)

    if resource.kind in @physical_device_kinds,
      do: resource,
      else: Repo.rollback(:unsupported_resource_kind)
  end

  defp validate_inventory_item_parent!(_scope, _item_id, _owner_resource_id, nil), do: :ok

  defp validate_inventory_item_parent!(scope, item_id, owner_resource_id, parent_id) do
    parent = scoped_get!(InventoryItem, scope.organization_id, parent_id)
    if parent.owner_resource_id != owner_resource_id, do: Repo.rollback(:parent_owner_mismatch)

    if item_id && inventory_item_descendant?(scope.organization_id, item_id, parent_id),
      do: Repo.rollback(:hierarchy_cycle)
  end

  defp inventory_item_descendant?(organization_id, parent_id, possible_descendant_id) do
    %{rows: rows} =
      Repo.query!(
        """
        WITH RECURSIVE descendants AS (
          SELECT id FROM inventory_items WHERE organization_id = $1 AND parent_id = $2
          UNION ALL
          SELECT child.id FROM inventory_items child
          JOIN descendants descendant ON child.parent_id = descendant.id
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

  defp lock_inventory_item_hierarchy(organization_id) do
    Repo.query!("SELECT pg_advisory_xact_lock(hashtext($1), hashtext($2))", [
      organization_id,
      @inventory_item_hierarchy_lock
    ])
  end

  defp reconcile_unconfirmed_hardware_type(scope, resource, assignment) do
    host = scoped_host(scope.organization_id, resource.id)

    case hardware_match_candidates(scope.organization_id, host, assignment) do
      [] ->
        resolve_match_finding(scope, resource.id)
        assignment

      [{hardware_type, revision, matched_by}] ->
        resolve_match_finding(scope, resource.id)

        put_hardware_assignment(
          scope,
          resource,
          hardware_type,
          revision_for_assignment(assignment, hardware_type, revision),
          "reconciled",
          matching_provenance(host, matched_by)
        )
        |> tap(&materialize_expected_components(scope, &1))

      candidates ->
        put_ambiguous_match_finding(scope, resource.id, host, candidates)
        assignment
    end
  end

  defp latest_hardware_revision!(organization_id, hardware_type_id) do
    TypeRevision
    |> where(
      [revision],
      revision.organization_id == ^organization_id and
        revision.hardware_type_id == ^hardware_type_id and not is_nil(revision.finalized_at)
    )
    |> order_by([revision], desc: revision.revision)
    |> limit(1)
    |> Repo.one()
    |> case do
      nil -> Repo.rollback(:hardware_type_has_no_revision)
      revision -> revision
    end
  end

  defp latest_module_revision!(organization_id, module_type_id) do
    TypeRevision
    |> where(
      [revision],
      revision.organization_id == ^organization_id and
        revision.module_type_id == ^module_type_id and not is_nil(revision.finalized_at)
    )
    |> order_by([revision], desc: revision.revision)
    |> limit(1)
    |> Repo.one()
    |> case do
      nil -> Repo.rollback(:module_type_has_no_revision)
      revision -> revision
    end
  end

  defp scoped_module_bay_owner!(organization_id, resource_id) do
    resource = scoped_get!(Resource, organization_id, resource_id)

    cond do
      resource.kind in @physical_device_kinds ->
        resource

      resource.kind == "module" and
          Repo.exists?(
            from module in Module,
              where:
                module.organization_id == ^organization_id and module.resource_id == ^resource.id
          ) ->
        resource

      true ->
        Repo.rollback(:unsupported_resource_kind)
    end
  end

  defp scoped_module_types!(organization_id, module_type_ids) when is_list(module_type_ids) do
    ids = Enum.uniq(module_type_ids)

    module_types =
      ModuleType
      |> where([module_type], module_type.organization_id == ^organization_id)
      |> where([module_type], module_type.id in ^ids)
      |> Repo.all()

    if length(module_types) == length(ids),
      do: module_types,
      else: Repo.rollback(:invalid_module_types)
  end

  defp scoped_module_types!(_organization_id, _module_type_ids),
    do: Repo.rollback(:invalid_module_types)

  defp replace_module_bay_compatibility(scope, bay, module_types) do
    ModuleBayCompatibleType
    |> where(
      [compatibility],
      compatibility.organization_id == ^scope.organization_id and
        compatibility.module_bay_id == ^bay.id
    )
    |> Repo.delete_all()

    Enum.each(module_types, fn module_type ->
      %ModuleBayCompatibleType{
        organization_id: scope.organization_id,
        module_bay_id: bay.id,
        module_type_id: module_type.id
      }
      |> ModuleBayCompatibleType.changeset()
      |> insert_or_rollback()
    end)
  end

  defp put_hardware_assignment(scope, resource, hardware_type, revision, origin, provenance) do
    assignment =
      locked_assignment(scope.organization_id, resource.id) ||
        %HardwareAssignment{
          organization_id: scope.organization_id,
          resource_id: resource.id
        }

    assignment = replace_changed_assignment(assignment, revision)

    assignment
    |> HardwareAssignment.changeset(%{
      hardware_type_id: hardware_type.id,
      catalog_type_revision_id: revision.id,
      origin: origin,
      provenance: provenance
    })
    |> upsert()
  end

  defp replace_changed_assignment(
         %HardwareAssignment{catalog_type_revision_id: revision_id} = assignment,
         %TypeRevision{id: revision_id}
       ),
       do: assignment

  defp replace_changed_assignment(%HardwareAssignment{id: id} = assignment, _revision)
       when not is_nil(id) do
    Repo.delete!(assignment)

    %HardwareAssignment{
      organization_id: assignment.organization_id,
      resource_id: assignment.resource_id
    }
  end

  defp replace_changed_assignment(assignment, _revision), do: assignment

  defp locked_assignment(organization_id, resource_id) do
    HardwareAssignment
    |> where(
      [assignment],
      assignment.organization_id == ^organization_id and assignment.resource_id == ^resource_id
    )
    |> lock("FOR UPDATE")
    |> Repo.one()
  end

  defp scoped_host(organization_id, resource_id) do
    Repo.get_by(Host, organization_id: organization_id, resource_id: resource_id)
  end

  defp hardware_match_candidates(_organization_id, nil, _assignment), do: []

  defp hardware_match_candidates(organization_id, %Host{vendor: vendor, model: model}, assignment)
       when is_binary(vendor) and is_binary(model) do
    HardwareType
    |> where([type], type.organization_id == ^organization_id)
    |> preload([:resource, manufacturer: :resource, revisions: ^latest_revisions_query()])
    |> Repo.all()
    |> Enum.flat_map(fn hardware_type ->
      revision = matching_revision(hardware_type, assignment)

      with true <- manufacturer_matches?(hardware_type.manufacturer, vendor),
           matched_by when not is_nil(matched_by) <- product_match(hardware_type, revision, model),
           %TypeRevision{} <- revision do
        [{hardware_type, revision, matched_by}]
      else
        _no_match -> []
      end
    end)
  end

  defp hardware_match_candidates(_organization_id, _host, _assignment), do: []

  defp matching_revision(
         %HardwareType{id: hardware_type_id, revisions: revisions},
         %HardwareAssignment{
           hardware_type_id: hardware_type_id,
           catalog_type_revision_id: revision_id
         }
       ),
       do: Enum.find(revisions, &(&1.id == revision_id))

  defp matching_revision(%HardwareType{revisions: revisions}, _assignment),
    do: List.first(revisions)

  defp latest_revisions_query do
    from revision in TypeRevision,
      where: not is_nil(revision.finalized_at),
      order_by: [desc: revision.revision]
  end

  defp manufacturer_matches?(manufacturer, reported_vendor) do
    aliases =
      case Map.get(manufacturer.metadata, "aliases", []) do
        aliases when is_list(aliases) -> Enum.filter(aliases, &is_binary/1)
        _invalid -> []
      end

    [manufacturer.resource.name, manufacturer.slug | aliases]
    |> Enum.filter(&is_binary/1)
    |> Enum.any?(&(normalize_catalog_value(&1) == normalize_catalog_value(reported_vendor)))
  end

  defp product_match(hardware_type, revision, reported_model) do
    normalized_model = normalize_catalog_value(reported_model)

    cond do
      normalize_catalog_value(hardware_type.model) == normalized_model ->
        "model"

      revision && normalize_catalog_value(revision.part_number) == normalized_model ->
        "part_number"

      true ->
        nil
    end
  end

  defp normalize_catalog_value(value) when is_binary(value) do
    value
    |> String.trim()
    |> String.downcase()
    |> String.replace(~r/[^[:alnum:]]+/u, " ")
    |> String.trim()
  end

  defp normalize_catalog_value(_value), do: nil

  defp revision_for_assignment(
         %HardwareAssignment{hardware_type_id: hardware_type_id} = assignment,
         %HardwareType{id: hardware_type_id},
         _latest_revision
       ) do
    Repo.get!(TypeRevision, assignment.catalog_type_revision_id)
  end

  defp revision_for_assignment(_assignment, _hardware_type, latest_revision), do: latest_revision

  defp matching_provenance(host, matched_by) do
    %{
      "matched_by" => matched_by,
      "reported_vendor" => host.vendor,
      "reported_model" => host.model,
      "field_owners" => Map.take(Map.get(host.metadata, "field_owners", %{}), ["vendor", "model"])
    }
  end

  defp validate_exception_template!(_scope, _assignment, nil, action)
       when action in ["add", :add],
       do: :ok

  defp validate_exception_template!(scope, assignment, template_id, action)
       when action in ["suppress", "alter", :suppress, :alter] and not is_nil(template_id) do
    ComponentTemplate
    |> where(
      [template],
      template.id == ^template_id and template.organization_id == ^scope.organization_id and
        template.catalog_type_revision_id == ^assignment.catalog_type_revision_id
    )
    |> Repo.exists?()
    |> if(do: :ok, else: Repo.rollback(:invalid_component_template))
  end

  defp validate_exception_template!(_scope, _assignment, _template_id, _action),
    do: Repo.rollback(:invalid_exception)

  defp materialize_expected_components(scope, assignment) do
    ExpectedComponent
    |> where(
      [component],
      component.organization_id == ^scope.organization_id and
        component.hardware_assignment_id == ^assignment.id
    )
    |> Repo.delete_all()

    templates =
      ComponentTemplate
      |> where(
        [template],
        template.organization_id == ^scope.organization_id and
          template.catalog_type_revision_id == ^assignment.catalog_type_revision_id
      )
      |> order_by([template], asc: template.kind, asc: template.name)
      |> Repo.all()

    exceptions =
      ExpectedComponentException
      |> where(
        [exception],
        exception.organization_id == ^scope.organization_id and
          exception.hardware_assignment_id == ^assignment.id
      )
      |> Repo.all()

    by_template =
      exceptions
      |> Enum.reject(&is_nil(&1.component_template_id))
      |> Map.new(&{&1.component_template_id, &1})

    Enum.each(templates, fn template ->
      exception = Map.get(by_template, template.id)

      template
      |> template_expectation_attrs(exception)
      |> insert_expected_component(scope, assignment, template.id, exception)
    end)

    exceptions
    |> Enum.filter(&(&1.action == "add"))
    |> Enum.each(fn exception ->
      attrs =
        exception.changes
        |> Map.take(~w(label position description required attributes))
        |> Map.merge(%{"kind" => exception.kind, "name" => exception.name})

      insert_expected_component(attrs, scope, assignment, nil, exception)
    end)
  end

  defp template_expectation_attrs(template, exception) do
    attrs = %{
      "kind" => template.kind,
      "name" => template.name,
      "label" => template.label,
      "position" => template.position,
      "description" => template.description,
      "required" => template.required,
      "attributes" => template.attributes,
      "suppressed" => not is_nil(exception) and exception.action == "suppress"
    }

    if exception && exception.action == "alter" do
      changes =
        Map.take(exception.changes, ~w(name label position description required attributes))

      case Map.fetch(changes, "attributes") do
        {:ok, attributes} when is_map(attributes) ->
          Map.put(changes, "attributes", Map.merge(template.attributes, attributes))

        _missing_or_invalid ->
          changes
      end
      |> then(&Map.merge(attrs, &1))
    else
      attrs
    end
  end

  defp insert_expected_component(attrs, scope, assignment, template_id, exception) do
    attrs =
      attrs
      |> Map.put("catalog_type_revision_id", assignment.catalog_type_revision_id)
      |> Map.put("component_template_id", template_id)
      |> Map.put("exception_id", exception && exception.id)

    %ExpectedComponent{
      organization_id: scope.organization_id,
      hardware_assignment_id: assignment.id
    }
    |> ExpectedComponent.changeset(attrs)
    |> insert_or_rollback()
  end

  defp put_ambiguous_match_finding(scope, resource_id, host, candidates) do
    details = %{
      "reported_vendor" => host.vendor,
      "reported_model" => host.model,
      "candidate_hardware_type_ids" => Enum.map(candidates, fn {type, _, _} -> type.id end)
    }

    finding =
      match_finding_query(scope.organization_id, resource_id)
      |> Repo.one() ||
        %HardwareMatchFinding{
          organization_id: scope.organization_id,
          resource_id: resource_id
        }

    finding
    |> HardwareMatchFinding.changeset(%{
      kind: "ambiguous_catalog_match",
      message: "Host facts match more than one hardware type",
      details: details
    })
    |> upsert()
  end

  defp resolve_match_finding(scope, resource_id) do
    match_finding_query(scope.organization_id, resource_id)
    |> Repo.one()
    |> case do
      nil ->
        nil

      finding ->
        finding
        |> HardwareMatchFinding.changeset(%{
          status: "resolved",
          resolved_at: Renga.Time.utc_now_ms()
        })
        |> update_or_rollback()
    end
  end

  defp match_finding_query(organization_id, resource_id) do
    from finding in HardwareMatchFinding,
      where:
        finding.organization_id == ^organization_id and finding.resource_id == ^resource_id and
          finding.kind == "ambiguous_catalog_match" and finding.status == "open"
  end

  defp find_expected_component_exception(scope, assignment, attrs) do
    case attr(attrs, :exception_id) do
      nil ->
        case attr(attrs, :component_template_id) do
          nil ->
            nil

          template_id ->
            Repo.get_by(ExpectedComponentException,
              organization_id: scope.organization_id,
              hardware_assignment_id: assignment.id,
              component_template_id: template_id
            )
        end

      exception_id ->
        ExpectedComponentException
        |> where(
          [exception],
          exception.id == ^exception_id and exception.organization_id == ^scope.organization_id and
            exception.hardware_assignment_id == ^assignment.id
        )
        |> Repo.one!()
    end
  end

  defp next_revision(organization_id, owner_field, type_id) do
    TypeRevision
    |> where([revision], revision.organization_id == ^organization_id)
    |> where([revision], field(revision, ^owner_field) == ^type_id)
    |> select([revision], coalesce(max(revision.revision), 0) + 1)
    |> Repo.one()
  end

  defp owner_field(HardwareType), do: :hardware_type_id
  defp owner_field(ModuleType), do: :module_type_id

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
    if "catalog_reconciler" in roles do
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

  defp upsert(%Ecto.Changeset{data: %{id: nil}} = changeset), do: insert_or_rollback(changeset)
  defp upsert(changeset), do: update_or_rollback(changeset)

  defp attr(attrs, key), do: Map.get(attrs, key) || Map.get(attrs, Atom.to_string(key))

  defp put_attr(attrs, key, value) do
    if Map.has_key?(attrs, Atom.to_string(key)) do
      Map.put(attrs, Atom.to_string(key), value)
    else
      Map.put(attrs, key, value)
    end
  end
end
