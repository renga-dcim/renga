defmodule Renga.CatalogModuleTest do
  use Renga.DataCase, async: true

  import Renga.AccountsFixtures
  import Renga.InventoryFixtures

  alias Renga.Accounts
  alias Renga.Catalog
  alias Renga.Catalog.Module
  alias Renga.Catalog.ModuleBay
  alias Renga.Inventory
  alias Renga.Repo

  setup do
    user = user_fixture()
    organization = organization_fixture()
    membership = organization_membership_fixture(user, organization, %{role: "admin"})
    scope = Accounts.scope_for_user(user, organization.id)
    %{scope: scope, organization: organization, membership: membership}
  end

  test "creates resource-backed modules pinned to immutable type revisions", %{scope: scope} do
    module_type = module_type_fixture(scope, "LC-48")

    {:ok, first_revision} =
      Catalog.create_module_type_revision(scope, module_type, %{part_number: "PN-1"})

    assert {:ok, module} =
             Catalog.create_module(
               scope,
               module_type,
               %{name: "Line card 001", lifecycle_state: "active"},
               %{status: "spare", serial_number: " SERIAL-1 ", asset_tag: " LC-001 "}
             )

    assert module.resource.kind == "module"
    assert module.module_type_id == module_type.id
    assert module.catalog_type_revision_id == first_revision.id
    assert module.serial_number == "SERIAL-1"
    assert module.asset_tag == "LC-001"

    {:ok, _second_revision} =
      Catalog.create_module_type_revision(scope, module_type, %{part_number: "PN-2"})

    assert Catalog.get_module!(scope, module.id).catalog_type_revision_id == first_revision.id
    assert Enum.map(Catalog.list_modules(scope), & &1.id) == [module.id]
  end

  test "creates stable bays on devices and modules with explicit compatibility", %{scope: scope} do
    owner = resource_fixture(scope, "chassis-owner")
    first_type = module_type_fixture(scope, "LC-48")
    second_type = module_type_fixture(scope, "SUP-2")
    {:ok, _revision} = Catalog.create_module_type_revision(scope, first_type, %{})

    assert {:ok, bay} =
             Catalog.create_module_bay(
               scope,
               owner.id,
               %{name: " Slot 1 ", label: " Primary ", position: " 1 "},
               [first_type.id]
             )

    assert bay.name == "Slot 1"
    assert bay.owner_kind == "server"
    assert bay.label == "Primary"
    assert Enum.map(bay.compatible_module_types, & &1.id) == [first_type.id]

    assert {:ok, updated_bay} =
             Catalog.set_module_bay_compatible_types(scope, bay, [second_type.id, first_type.id])

    assert updated_bay.compatible_module_types |> Enum.map(& &1.id) |> Enum.sort() ==
             Enum.sort([first_type.id, second_type.id])

    {:ok, module} =
      Catalog.create_module(
        scope,
        first_type,
        %{name: "Nested owner", lifecycle_state: "active"}
      )

    assert {:ok, nested_bay} =
             Catalog.create_module_bay(scope, module.resource_id, %{name: "Daughter slot"}, [
               second_type.id
             ])

    assert nested_bay.owner_kind == "module"

    assert Enum.map(Catalog.list_module_bays(scope, module.resource_id), & &1.id) == [
             nested_bay.id
           ]
  end

  test "rejects unsupported owners and foreign compatibility types", %{scope: scope} do
    module_type = module_type_fixture(scope, "LC-48")

    {:ok, manufacturer} =
      Catalog.create_manufacturer(
        scope,
        %{name: "Not a bay owner", lifecycle_state: "active"},
        %{slug: "not-a-bay-owner"}
      )

    assert {:error, :unsupported_resource_kind} =
             Catalog.create_module_bay(scope, manufacturer.resource_id, %{name: "Invalid"})

    other_user = user_fixture()
    other_organization = organization_fixture()
    organization_membership_fixture(other_user, other_organization, %{role: "admin"})
    other_scope = Accounts.scope_for_user(other_user, other_organization.id)
    foreign_type = module_type_fixture(other_scope, "FOREIGN")
    owner = resource_fixture(scope, "compatibility-owner")

    assert {:error, :invalid_module_types} =
             Catalog.create_module_bay(scope, owner.id, %{name: "Invalid compatibility"}, [
               module_type.id,
               foreign_type.id
             ])
  end

  test "database rejects mismatched module revisions and bay owner kinds", %{scope: scope} do
    first_type = module_type_fixture(scope, "LC-48")
    second_type = module_type_fixture(scope, "SUP-2")
    {:ok, first_revision} = Catalog.create_module_type_revision(scope, first_type, %{})
    {:ok, second_revision} = Catalog.create_module_type_revision(scope, second_type, %{})
    resource = resource_fixture(scope, "module-envelope")

    assert {:error, module_changeset} =
             %Module{
               organization_id: scope.organization_id,
               resource_id: resource.id,
               module_type_id: first_type.id,
               catalog_type_revision_id: second_revision.id
             }
             |> Module.changeset(%{})
             |> Repo.insert()

    assert %{catalog_type_revision: [_]} = errors_on(module_changeset)

    assert {:error, bay_changeset} =
             %ModuleBay{
               organization_id: scope.organization_id,
               owner_resource_id: resource.id,
               owner_kind: "module"
             }
             |> ModuleBay.changeset(%{name: "Forged owner"})
             |> Repo.insert()

    assert %{owner_resource: [_]} = errors_on(bay_changeset)
    assert first_revision.module_type_id == first_type.id
  end

  test "module and bay mutations require current management access", %{
    scope: scope,
    membership: membership
  } do
    module_type = module_type_fixture(scope, "LC-48")
    {:ok, _revision} = Catalog.create_module_type_revision(scope, module_type, %{})
    owner = resource_fixture(scope, "managed-bay-owner")
    {:ok, _membership} = Accounts.update_organization_membership(membership, %{role: "member"})

    assert {:error, :forbidden} =
             Catalog.create_module(
               scope,
               module_type,
               %{name: "Forbidden module", lifecycle_state: "active"}
             )

    assert {:error, :forbidden} =
             Catalog.create_module_bay(scope, owner.id, %{name: "Forbidden bay"})

    assert {:error, :forbidden} =
             Inventory.create_resource(scope, %{kind: "module", name: "Orphan module"})
  end

  defp module_type_fixture(scope, model) do
    {:ok, manufacturer} =
      Catalog.create_manufacturer(
        scope,
        %{name: "Vendor #{model}", lifecycle_state: "active"},
        %{slug: "vendor-#{String.downcase(model) |> String.replace(~r/[^a-z0-9]+/, "-")}"}
      )

    {:ok, module_type} =
      Catalog.create_module_type(
        scope,
        %{name: "Module type #{model}", lifecycle_state: "active"},
        %{manufacturer_id: manufacturer.id, model: model, module_class: "line_card"}
      )

    module_type
  end

  defp resource_fixture(scope, name) do
    {:ok, resource} =
      Inventory.create_resource(scope, %{kind: "server", name: name, lifecycle_state: "active"})

    resource
  end
end
