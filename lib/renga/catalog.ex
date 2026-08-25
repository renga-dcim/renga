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
  alias Renga.Catalog.HardwareAssignment
  alias Renga.Catalog.HardwareMatchFinding
  alias Renga.Catalog.HardwareType
  alias Renga.Catalog.Manufacturer
  alias Renga.Catalog.ModuleType
  alias Renga.Catalog.TypeRevision
  alias Renga.Inventory
  alias Renga.Inventory.Host
  alias Renga.Inventory.Resource
  alias Renga.Repo

  @physical_device_kinds ~w(server switch pdu storage)

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
        host = scoped_host(scope.organization_id, resource.id)
        candidates = hardware_match_candidates(scope.organization_id, host)

        case candidates do
          [] ->
            resolve_match_finding(scope, resource.id)
            delete_reconciled_assignment(assignment)
            nil

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

          candidates ->
            put_ambiguous_match_finding(scope, resource.id, host, candidates)
            delete_reconciled_assignment(assignment)
            nil
        end
      end
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

  defp put_hardware_assignment(scope, resource, hardware_type, revision, origin, provenance) do
    assignment =
      locked_assignment(scope.organization_id, resource.id) ||
        %HardwareAssignment{
          organization_id: scope.organization_id,
          resource_id: resource.id
        }

    assignment
    |> HardwareAssignment.changeset(%{
      hardware_type_id: hardware_type.id,
      catalog_type_revision_id: revision.id,
      origin: origin,
      provenance: provenance
    })
    |> upsert()
  end

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

  defp hardware_match_candidates(_organization_id, nil), do: []

  defp hardware_match_candidates(organization_id, %Host{vendor: vendor, model: model})
       when is_binary(vendor) and is_binary(model) do
    HardwareType
    |> where([type], type.organization_id == ^organization_id)
    |> preload([:resource, manufacturer: :resource, revisions: ^latest_revisions_query()])
    |> Repo.all()
    |> Enum.flat_map(fn hardware_type ->
      revision = List.first(hardware_type.revisions)

      with true <- manufacturer_matches?(hardware_type.manufacturer, vendor),
           matched_by when not is_nil(matched_by) <- product_match(hardware_type, revision, model),
           %TypeRevision{} <- revision do
        [{hardware_type, revision, matched_by}]
      else
        _no_match -> []
      end
    end)
  end

  defp hardware_match_candidates(_organization_id, _host), do: []

  defp latest_revisions_query do
    from revision in TypeRevision,
      where: not is_nil(revision.finalized_at),
      order_by: [desc: revision.revision]
  end

  defp manufacturer_matches?(manufacturer, reported_vendor) do
    aliases = Map.get(manufacturer.metadata, "aliases", [])

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

  defp delete_reconciled_assignment(%HardwareAssignment{origin: "reconciled"} = assignment),
    do: Repo.delete!(assignment)

  defp delete_reconciled_assignment(_assignment), do: nil

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

  defp put_attr(attrs, key, value) do
    if Map.has_key?(attrs, Atom.to_string(key)) do
      Map.put(attrs, Atom.to_string(key), value)
    else
      Map.put(attrs, key, value)
    end
  end
end
