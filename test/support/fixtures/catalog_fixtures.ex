defmodule Renga.CatalogFixtures do
  @moduledoc """
  Test helpers for hardware types, their revisions, and resources assigned
  to them.
  """

  alias Renga.Catalog
  alias Renga.Inventory

  @doc "Creates a manufacturer whose slug derives from `suffix`."
  def catalog_manufacturer_fixture(scope, suffix) do
    slug = suffix |> String.downcase() |> String.replace(~r/[^a-z0-9]+/, "-")

    {:ok, manufacturer} =
      Catalog.create_manufacturer(
        scope,
        %{name: "Vendor #{suffix}", lifecycle_state: "active"},
        %{slug: slug}
      )

    manufacturer
  end

  @doc """
  Creates a server hardware type with one published revision holding
  `templates`, such as `%{kind: "memory", name: "DIMM A1", position: "A1"}`.
  """
  def catalog_hardware_type_fixture(scope, model, templates \\ []) do
    manufacturer = catalog_manufacturer_fixture(scope, "hw-#{model}")

    {:ok, hardware_type} =
      Catalog.create_hardware_type(
        scope,
        %{name: "hardware-type-#{model}", lifecycle_state: "active"},
        %{manufacturer_id: manufacturer.id, model: model, device_class: "server"}
      )

    {:ok, _revision} = Catalog.create_hardware_type_revision(scope, hardware_type, %{}, templates)
    hardware_type
  end

  @doc """
  Creates a server assigned to a new hardware type with `templates`, and
  returns the resource with its expected components keyed by name.
  """
  def assigned_server_fixture(scope, name, templates) do
    {:ok, resource} =
      Inventory.create_resource(scope, %{kind: "server", name: name, lifecycle_state: "active"})

    hardware_type = catalog_hardware_type_fixture(scope, "#{name}-type", templates)
    {:ok, _assignment} = Catalog.assign_hardware_type(scope, resource.id, hardware_type.id)

    expected =
      scope
      |> Catalog.list_expected_components(resource.id)
      |> Map.new(&{&1.name, &1})

    {resource, expected}
  end

  @doc """
  Records an observed component on `resource` as reconciliation would,
  such as `actual_component_fixture(scope, server, "memory", "A1",
  part_number: "M-32G")`.
  """
  def actual_component_fixture(scope, resource, kind, slot, attrs \\ []) do
    now = DateTime.utc_now()

    %Renga.Catalog.ActualComponent{
      organization_id: scope.organization_id,
      owner_resource_id: resource.id
    }
    |> Renga.Catalog.ActualComponent.changeset(
      %{kind: kind, name: "#{kind} #{slot}", slot: slot}
      |> Map.merge(Map.new(attrs))
      |> Map.merge(%{first_observed_at: now, last_observed_at: now})
    )
    |> Renga.Repo.insert!()
  end
end
