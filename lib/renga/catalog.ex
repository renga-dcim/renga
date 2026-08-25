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
  alias Renga.Catalog.HardwareType
  alias Renga.Catalog.Manufacturer
  alias Renga.Catalog.ModuleType
  alias Renga.Catalog.TypeRevision
  alias Renga.Inventory
  alias Renga.Repo

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

  defp put_attr(attrs, key, value) do
    if Map.has_key?(attrs, Atom.to_string(key)) do
      Map.put(attrs, Atom.to_string(key), value)
    else
      Map.put(attrs, key, value)
    end
  end
end
