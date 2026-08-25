defmodule Renga.CatalogTest do
  use Renga.DataCase, async: true

  import Renga.AccountsFixtures
  import Renga.InventoryFixtures

  alias Renga.Accounts
  alias Renga.Catalog
  alias Renga.Inventory.Resource
  alias Renga.Repo

  setup do
    user = user_fixture()
    organization = organization_fixture()
    organization_membership_fixture(user, organization, %{role: "admin"})
    scope = Accounts.scope_for_user(user, organization.id)
    %{scope: scope, organization: organization}
  end

  test "creates resource-backed manufacturers and tenant-scoped catalog types", %{scope: scope} do
    assert {:ok, manufacturer} = manufacturer_fixture(scope, "  Acme  ", " Acme-Hardware ")
    assert manufacturer.slug == "acme-hardware"
    assert manufacturer.resource.kind == "manufacturer"

    assert {:ok, hardware_type} =
             Catalog.create_hardware_type(
               scope,
               %{name: "Acme Rack Server", lifecycle_state: "active"},
               %{
                 manufacturer_id: manufacturer.id,
                 model: "  RS-42  ",
                 device_class: "server",
                 metadata: %{"family" => "rack"}
               }
             )

    assert hardware_type.model == "RS-42"
    assert hardware_type.resource.kind == "hardware_type"

    assert {:ok, module_type} =
             Catalog.create_module_type(
               scope,
               %{name: "Acme 48-port card", lifecycle_state: "active"},
               %{
                 manufacturer_id: manufacturer.id,
                 model: "LC-48",
                 module_class: "line_card"
               }
             )

    assert module_type.resource.kind == "module_type"
    assert Enum.map(Catalog.list_manufacturers(scope), & &1.id) == [manufacturer.id]
    assert Enum.map(Catalog.list_hardware_types(scope), & &1.id) == [hardware_type.id]
    assert Enum.map(Catalog.list_module_types(scope), & &1.id) == [module_type.id]
  end

  test "manufacturer and model uniqueness is case-insensitive within each type category", %{
    scope: scope
  } do
    {:ok, manufacturer} = manufacturer_fixture(scope, "Acme", "acme")

    assert {:ok, _hardware_type} =
             hardware_type_fixture(scope, manufacturer, "RS-42", "server")

    assert {:error, %Ecto.Changeset{errors: [model: {"has already been taken", _}]}} =
             hardware_type_fixture(scope, manufacturer, "rs-42", "server")

    assert {:ok, _module_type} =
             module_type_fixture(scope, manufacturer, "RS-42", "line_card")
  end

  test "revisions retain typed specifications and immutable component snapshots", %{scope: scope} do
    {:ok, manufacturer} = manufacturer_fixture(scope, "Acme", "acme")
    {:ok, hardware_type} = hardware_type_fixture(scope, manufacturer, "RS-42", "server")

    assert {:ok, first_revision} =
             Catalog.create_hardware_type_revision(
               scope,
               hardware_type,
               %{
                 part_number: "PN-1",
                 height_units: 2,
                 width_mm: "482.60",
                 depth_mm: "800.00",
                 weight_kg: "18.500",
                 airflow: "front_to_rear",
                 specifications: %{"cpu_sockets" => 2}
               },
               [
                 %{kind: "interface", name: "eth0", attributes: %{"speed_mbps" => 10_000}},
                 %{kind: "module_bay", name: "PSU1", position: "rear-left"}
               ]
             )

    assert first_revision.revision == 1
    assert first_revision.height_units == 2
    assert Enum.map(first_revision.component_templates, & &1.name) == ["PSU1", "eth0"]

    assert {:ok, second_revision} =
             Catalog.create_hardware_type_revision(
               scope,
               hardware_type,
               %{part_number: "PN-2", height_units: 4},
               [%{kind: "interface", name: "eth1", required: false}]
             )

    assert second_revision.revision == 2

    stored = Catalog.get_hardware_type!(scope, hardware_type.id)
    assert Enum.map(stored.revisions, & &1.revision) == [2, 1]

    assert stored.revisions
           |> Enum.at(1)
           |> Map.fetch!(:component_templates)
           |> Enum.map(& &1.name) == ["PSU1", "eth0"]
  end

  test "module types use the same versioned template contract", %{scope: scope} do
    {:ok, manufacturer} = manufacturer_fixture(scope, "Acme", "acme")
    {:ok, module_type} = module_type_fixture(scope, manufacturer, "LC-48", "line_card")

    assert {:ok, revision} =
             Catalog.create_module_type_revision(
               scope,
               module_type,
               %{part_number: "LC48-PN"},
               [%{kind: "interface", name: "xe-0/0/0"}]
             )

    assert revision.revision == 1
    assert revision.module_type_id == module_type.id
    assert is_nil(revision.hardware_type_id)
  end

  test "rejects cross-tenant catalog relationships and reads", %{scope: scope} do
    {:ok, manufacturer} = manufacturer_fixture(scope, "Private Vendor", "private-vendor")

    other_user = user_fixture()
    other_organization = organization_fixture()
    organization_membership_fixture(other_user, other_organization, %{role: "admin"})
    other_scope = Accounts.scope_for_user(other_user, other_organization.id)

    assert_raise Ecto.NoResultsError, fn ->
      Catalog.get_manufacturer!(other_scope, manufacturer.id)
    end

    assert {:error, %Ecto.Changeset{}} =
             hardware_type_fixture(other_scope, manufacturer, "Foreign", "server")
  end

  test "catalog mutations require a current owner or admin membership", %{
    organization: organization
  } do
    member = user_fixture()
    organization_membership_fixture(member, organization, %{role: "member"})
    member_scope = Accounts.scope_for_user(member, organization.id)

    assert {:error, :forbidden} =
             Catalog.create_manufacturer(
               member_scope,
               %{name: "Forbidden", lifecycle_state: "active"},
               %{slug: "forbidden"}
             )

    refute Repo.get_by(Resource, kind: "manufacturer", name: "Forbidden")
  end

  test "invalid templates roll back the entire revision", %{scope: scope} do
    {:ok, manufacturer} = manufacturer_fixture(scope, "Acme", "acme")
    {:ok, hardware_type} = hardware_type_fixture(scope, manufacturer, "RS-42", "server")

    assert {:error, %Ecto.Changeset{}} =
             Catalog.create_hardware_type_revision(
               scope,
               hardware_type,
               %{height_units: 2},
               [%{kind: "unknown", name: "mystery"}]
             )

    assert Catalog.get_hardware_type!(scope, hardware_type.id).revisions == []
  end

  defp manufacturer_fixture(scope, name, slug) do
    Catalog.create_manufacturer(
      scope,
      %{name: name, lifecycle_state: "active"},
      %{slug: slug}
    )
  end

  defp hardware_type_fixture(scope, manufacturer, model, device_class) do
    Catalog.create_hardware_type(
      scope,
      %{name: "#{manufacturer.id}-hardware-#{model}", lifecycle_state: "active"},
      %{manufacturer_id: manufacturer.id, model: model, device_class: device_class}
    )
  end

  defp module_type_fixture(scope, manufacturer, model, module_class) do
    Catalog.create_module_type(
      scope,
      %{name: "#{manufacturer.id}-module-#{model}", lifecycle_state: "active"},
      %{manufacturer_id: manufacturer.id, model: model, module_class: module_class}
    )
  end
end
