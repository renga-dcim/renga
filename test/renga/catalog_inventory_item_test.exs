defmodule Renga.CatalogInventoryItemTest do
  use Renga.DataCase, async: true

  import Renga.AccountsFixtures
  import Renga.InventoryFixtures

  alias Renga.Accounts
  alias Renga.Catalog
  alias Renga.Catalog.InventoryItem
  alias Renga.Inventory
  alias Renga.Repo

  setup do
    user = user_fixture()
    organization = organization_fixture()
    membership = organization_membership_fixture(user, organization, %{role: "admin"})
    scope = Accounts.scope_for_user(user, organization.id)
    %{scope: scope, organization: organization, membership: membership}
  end

  test "creates nested inventory-only parts with typed asset fields", %{scope: scope} do
    owner = resource_fixture(scope, "parts-device")

    assert {:ok, assembly} =
             Catalog.create_inventory_item(scope, owner.id, %{
               name: "  System Board  ",
               kind: "fru",
               status: "installed",
               part_number: " BOARD-1 ",
               metadata: %{"revision" => "A"}
             })

    assert {:ok, dimm} =
             Catalog.create_inventory_item(scope, owner.id, %{
               parent_id: assembly.id,
               name: "DIMM A1",
               kind: "dimm",
               status: "installed",
               position: " A1 ",
               serial_number: " SERIAL-1 "
             })

    assert assembly.name == "System Board"
    assert assembly.part_number == "BOARD-1"
    assert dimm.parent_id == assembly.id
    assert dimm.position == "A1"
    assert dimm.serial_number == "SERIAL-1"

    stored = Catalog.get_inventory_item!(scope, assembly.id)
    assert Enum.map(stored.children, & &1.id) == [dimm.id]

    assert Enum.map(Catalog.list_inventory_items(scope, owner.id), & &1.name) == [
             "DIMM A1",
             "System Board"
           ]

    assert {:error, duplicate_changeset} =
             Catalog.create_inventory_item(scope, owner.id, %{
               name: "system board",
               kind: "fru"
             })

    assert %{name: [_]} = errors_on(duplicate_changeset)
  end

  test "deleting an owning resource removes its complete part hierarchy", %{scope: scope} do
    owner = resource_fixture(scope, "deleted-parts-device")
    {:ok, parent} = item_fixture(scope, owner, "Parent")
    {:ok, child} = item_fixture(scope, owner, "Child", parent.id)

    Repo.delete!(owner)

    refute Repo.get(InventoryItem, parent.id)
    refute Repo.get(InventoryItem, child.id)
  end

  test "accepts a blank form parent as an unparented item", %{scope: scope} do
    owner = resource_fixture(scope, "blank-parent-device")

    assert {:ok, item} =
             Catalog.create_inventory_item(scope, owner.id, %{
               "parent_id" => "",
               "name" => "Root part",
               "kind" => "fru"
             })

    assert is_nil(item.parent_id)
  end

  test "blank required names return validation errors", %{scope: scope} do
    owner = resource_fixture(scope, "blank-name-device")
    {:ok, item} = item_fixture(scope, owner, "Named part")

    assert {:error, changeset} = Catalog.update_inventory_item(scope, item, %{"name" => ""})
    assert %{name: [_]} = errors_on(changeset)
  end

  test "rejects cycles and parents owned by another resource", %{scope: scope} do
    first_owner = resource_fixture(scope, "first-parts-device")
    second_owner = resource_fixture(scope, "second-parts-device")
    {:ok, parent} = item_fixture(scope, first_owner, "Parent")
    {:ok, child} = item_fixture(scope, first_owner, "Child", parent.id)
    {:ok, foreign_parent} = item_fixture(scope, second_owner, "Foreign")

    assert {:error, :hierarchy_cycle} =
             Catalog.update_inventory_item(scope, parent, %{parent_id: child.id})

    assert {:error, :parent_owner_mismatch} =
             Catalog.update_inventory_item(scope, child, %{parent_id: foreign_parent.id})

    assert {:error, self_parent_changeset} =
             child
             |> InventoryItem.changeset(%{parent_id: child.id})
             |> Repo.update()

    assert %{parent_id: [_]} = errors_on(self_parent_changeset)
  end

  test "database enforces owner, parent, and tenant relationships", %{scope: scope} do
    owner = resource_fixture(scope, "bounded-parts-device")
    other_owner = resource_fixture(scope, "other-bounded-parts-device")
    {:ok, parent} = item_fixture(scope, owner, "Parent")

    assert {:error, wrong_owner_changeset} =
             %InventoryItem{
               organization_id: scope.organization_id,
               owner_resource_id: other_owner.id
             }
             |> InventoryItem.changeset(%{
               parent_id: parent.id,
               name: "Wrong owner",
               kind: "fru"
             })
             |> Repo.insert()

    assert %{parent: [_]} = errors_on(wrong_owner_changeset)

    other_user = user_fixture()
    other_organization = organization_fixture()
    organization_membership_fixture(other_user, other_organization, %{role: "admin"})
    other_scope = Accounts.scope_for_user(other_user, other_organization.id)

    assert_raise Ecto.NoResultsError, fn ->
      Catalog.get_inventory_item!(other_scope, parent.id)
    end

    assert {:error, foreign_owner_changeset} =
             %InventoryItem{
               organization_id: other_scope.organization_id,
               owner_resource_id: owner.id
             }
             |> InventoryItem.changeset(%{name: "Foreign", kind: "fru"})
             |> Repo.insert()

    assert %{owner_resource: [_]} = errors_on(foreign_owner_changeset)
  end

  test "mutations require current management access and a physical owner", %{
    scope: scope,
    membership: membership
  } do
    owner = resource_fixture(scope, "managed-parts-device")

    {:ok, manufacturer} =
      Catalog.create_manufacturer(
        scope,
        %{name: "Not a device", lifecycle_state: "active"},
        %{slug: "not-a-device"}
      )

    assert {:error, :unsupported_resource_kind} =
             Catalog.create_inventory_item(scope, manufacturer.resource_id, %{
               name: "Invalid",
               kind: "fru"
             })

    {:ok, _membership} = Accounts.update_organization_membership(membership, %{role: "member"})

    assert {:error, :forbidden} =
             Catalog.create_inventory_item(scope, owner.id, %{name: "Forbidden", kind: "fru"})
  end

  defp resource_fixture(scope, name) do
    {:ok, resource} =
      Inventory.create_resource(scope, %{kind: "server", name: name, lifecycle_state: "active"})

    resource
  end

  defp item_fixture(scope, owner, name, parent_id \\ nil) do
    Catalog.create_inventory_item(scope, owner.id, %{
      name: name,
      kind: "fru",
      parent_id: parent_id
    })
  end
end
