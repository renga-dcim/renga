defmodule Renga.Inventory.ChangesTest do
  use Renga.DataCase, async: true

  import Renga.AccountsFixtures
  import Renga.InventoryFixtures

  alias Renga.Inventory
  alias Renga.Inventory.Changes

  setup do
    organization = organization_fixture()
    admin = user_fixture()
    organization_membership_fixture(admin, organization, %{role: "admin"})
    scope = Renga.Accounts.scope_for_user(admin, organization.id)
    :ok = Changes.subscribe(scope)
    %{scope: scope, organization_id: organization.id}
  end

  test "announces only successes and passes the result through", %{organization_id: id} do
    assert {:ok, :value} = Changes.broadcast({:ok, :value}, id)
    assert_receive {:inventory_changed, ^id}

    assert {:ok, :resource, true} = Changes.broadcast({:ok, :resource, true}, id)
    assert_receive {:inventory_changed, ^id}

    assert {:error, :nope} = Changes.broadcast({:error, :nope}, id)
    refute_receive {:inventory_changed, _}
  end

  test "other organizations' changes are not delivered", %{organization_id: id} do
    other = organization_fixture()
    Changes.broadcast({:ok, nil}, other.id)

    refute_receive {:inventory_changed, _}
    Changes.broadcast({:ok, nil}, id)
    assert_receive {:inventory_changed, ^id}
  end

  test "context changes announce themselves after committing", %{
    scope: scope,
    organization_id: id
  } do
    {:ok, resource} =
      Inventory.create_resource(scope, %{
        kind: "server",
        name: "live-01",
        lifecycle_state: "active"
      })

    {:ok, _condition} =
      Inventory.put_resource_condition(scope, resource.id, %{
        type: "InventoryCurrent",
        status: "true"
      })

    assert_receive {:inventory_changed, ^id}

    {:ok, 1} = Inventory.update_resources_lifecycle(scope, [resource.id], "retired")
    assert_receive {:inventory_changed, ^id}

    resource = Inventory.get_resource!(scope, resource.id)
    {:ok, _resource} = Inventory.update_resource_lifecycle(scope, resource, "active")
    assert_receive {:inventory_changed, ^id}
  end
end
