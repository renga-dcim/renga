defmodule Renga.CatalogConcurrencyTest do
  use ExUnit.Case, async: false

  import Renga.AccountsFixtures
  import Renga.InventoryFixtures

  alias Ecto.Adapters.SQL.Sandbox
  alias Renga.Accounts
  alias Renga.Catalog
  alias Renga.Inventory
  alias Renga.Repo

  @timeout 5_000

  test "concurrent revision creation serializes numbering on the catalog type" do
    with_catalog(fn scope, hardware_type ->
      test_process = self()

      first_task =
        concurrent(fn ->
          Repo.transaction(fn ->
            result =
              Catalog.create_hardware_type_revision(scope, hardware_type, %{part_number: "first"})

            send(test_process, :first_revision_ready)

            receive do
              :release_first_revision -> result
            end
          end)
        end)

      assert_receive :first_revision_ready, 1_000

      second_task =
        concurrent(fn ->
          Catalog.create_hardware_type_revision(scope, hardware_type, %{part_number: "second"})
        end)

      assert Task.yield(second_task, 200) == nil
      send(first_task.pid, :release_first_revision)

      assert {:ok, {:ok, first}} = Task.await(first_task)
      assert {:ok, second} = Task.await(second_task)
      assert Enum.sort([first.revision, second.revision]) == [1, 2]

      assert Catalog.get_hardware_type!(scope, hardware_type.id).revisions
             |> Enum.map(& &1.revision) == [2, 1]
    end)
  end

  test "concurrent inverse-parent updates cannot create an inventory item cycle" do
    with_catalog(fn scope, _hardware_type ->
      {:ok, owner} =
        Renga.Inventory.create_resource(scope, %{
          kind: "server",
          name: "Hierarchy owner",
          lifecycle_state: "active"
        })

      {:ok, first} = Catalog.create_inventory_item(scope, owner.id, %{name: "First", kind: "fru"})

      {:ok, second} =
        Catalog.create_inventory_item(scope, owner.id, %{name: "Second", kind: "fru"})

      test_process = self()

      first_task =
        concurrent(fn ->
          Repo.transaction(fn ->
            result = Catalog.update_inventory_item(scope, first, %{parent_id: second.id})
            send(test_process, :first_parent_ready)

            receive do
              :release_first_parent -> result
            end
          end)
        end)

      assert_receive :first_parent_ready, 1_000

      lock_probe =
        concurrent(fn ->
          Repo.query!("SELECT pg_try_advisory_xact_lock(hashtext($1), hashtext($2))", [
            scope.organization_id,
            "catalog-inventory-item-hierarchy"
          ])
        end)

      assert %Postgrex.Result{rows: [[false]]} = Task.await(lock_probe)

      second_task =
        concurrent(fn -> Catalog.update_inventory_item(scope, second, %{parent_id: first.id}) end)

      assert Task.yield(second_task, 200) == nil
      send(first_task.pid, :release_first_parent)

      assert {:ok, {:ok, updated_first}} = Task.await(first_task)
      assert updated_first.parent_id == second.id
      assert {:error, :hierarchy_cycle} = Task.await(second_task)
    end)
  end

  test "concurrent inverse module installations cannot create a containment cycle" do
    with_catalog(fn scope, hardware_type ->
      module_type = module_type_fixture(scope, hardware_type, "MOD-1")
      first = module_fixture(scope, module_type, "First module")
      second = module_fixture(scope, module_type, "Second module")

      {:ok, first_bay} =
        Catalog.create_module_bay(scope, first.resource_id, %{name: "Child"}, [module_type.id])

      {:ok, second_bay} =
        Catalog.create_module_bay(scope, second.resource_id, %{name: "Child"}, [module_type.id])

      test_process = self()

      first_task =
        concurrent(fn ->
          Repo.transaction(fn ->
            result = Catalog.install_module(scope, first_bay.id, second.id)
            send(test_process, :first_installation_ready)

            receive do
              :release_first_installation -> result
            end
          end)
        end)

      assert_receive :first_installation_ready, 1_000

      lock_probe =
        concurrent(fn ->
          Repo.query!("SELECT pg_try_advisory_xact_lock(hashtext($1), hashtext($2))", [
            scope.organization_id,
            "catalog-module-hierarchy"
          ])
        end)

      assert %Postgrex.Result{rows: [[false]]} = Task.await(lock_probe)

      second_task =
        concurrent(fn -> Catalog.install_module(scope, second_bay.id, first.id) end)

      assert Task.yield(second_task, 200) == nil
      send(first_task.pid, :release_first_installation)

      assert {:ok, {:ok, first_installation}} = Task.await(first_task)
      assert first_installation.module_id == second.id
      assert {:error, :hierarchy_cycle} = Task.await(second_task)
    end)
  end

  test "concurrent promotion creates only one module for an inventory item" do
    with_catalog(fn scope, hardware_type ->
      module_type = module_type_fixture(scope, hardware_type, "PROMOTION-1")

      {:ok, owner} =
        Renga.Inventory.create_resource(scope, %{
          kind: "server",
          name: "Promotion owner",
          lifecycle_state: "active"
        })

      {:ok, item} =
        Catalog.create_inventory_item(scope, owner.id, %{
          name: "Promoted line card",
          kind: "fru",
          status: "installed"
        })

      test_process = self()

      first_task =
        concurrent(fn ->
          Repo.transaction(fn ->
            result = Catalog.promote_inventory_item_to_module(scope, item, module_type)
            send(test_process, :first_promotion_ready)

            receive do
              :release_first_promotion -> result
            end
          end)
        end)

      assert_receive :first_promotion_ready, 1_000

      second_task =
        concurrent(fn -> Catalog.promote_inventory_item_to_module(scope, item, module_type) end)

      assert Task.yield(second_task, 200) == nil
      send(first_task.pid, :release_first_promotion)

      assert {:ok, {:ok, promoted_module}} = Task.await(first_task)
      assert {:error, :inventory_item_already_promoted} = Task.await(second_task)
      assert Enum.map(Catalog.list_modules(scope), & &1.id) == [promoted_module.id]
    end)
  end

  test "catalog type creation uses a concurrently committed manufacturer name" do
    with_catalog(fn scope, hardware_type ->
      manufacturer = Catalog.get_manufacturer!(scope, hardware_type.manufacturer_id)
      test_process = self()

      rename_task =
        concurrent(fn ->
          Repo.transaction(fn ->
            result =
              Inventory.update_resource(scope, manufacturer.resource, %{
                name: "Renamed Vendor",
                display_name: "Renamed Vendor"
              })

            send(test_process, :manufacturer_rename_ready)

            receive do
              :release_manufacturer_rename -> result
            end
          end)
        end)

      assert_receive :manufacturer_rename_ready, 1_000

      create_task =
        concurrent(fn ->
          Catalog.create_module_type(
            scope,
            %{name: "Stale Vendor MOD-2", lifecycle_state: "active"},
            %{
              manufacturer_id: manufacturer.id,
              model: "  MOD-2  ",
              module_class: "line_card"
            }
          )
        end)

      assert Task.yield(create_task, 200) == nil
      send(rename_task.pid, :release_manufacturer_rename)

      assert {:ok, {:ok, renamed_resource}} = Task.await(rename_task)
      assert renamed_resource.name == "Renamed Vendor"
      assert {:ok, module_type} = Task.await(create_task)
      assert module_type.model == "MOD-2"
      assert module_type.resource.name == "Renamed Vendor MOD-2"
    end)
  end

  test "managed resource updates and catalog creation share a deadlock-safe lock order" do
    with_catalog(fn scope, hardware_type ->
      manufacturer = Catalog.get_manufacturer!(scope, hardware_type.manufacturer_id)

      Repo.query!("BEGIN")

      Repo.query!("SELECT id FROM resources WHERE id::text = $1 FOR UPDATE", [
        manufacturer.resource_id
      ])

      update_task =
        concurrent(fn ->
          Inventory.update_resource(scope, manufacturer.resource, %{
            name: "Ordered Vendor",
            display_name: "Ordered Vendor"
          })
        end)

      create_task =
        try do
          await_lock_waiters!(1, @timeout)

          task =
            concurrent(fn ->
              Catalog.create_module_type(
                scope,
                %{lifecycle_state: "active"},
                %{
                  manufacturer_id: manufacturer.id,
                  model: "ORDERED-1",
                  module_class: "line_card"
                }
              )
            end)

          await_lock_waiters!(2, @timeout)
          task
        after
          Repo.query!("COMMIT")
        end

      assert {:ok, updated_resource} = Task.await(update_task, @timeout)
      assert updated_resource.name == "Ordered Vendor"
      assert {:ok, module_type} = Task.await(create_task, @timeout)
      assert module_type.resource.name == "Ordered Vendor ORDERED-1"
    end)
  end

  defp concurrent(fun) do
    Task.async(fn ->
      :ok = Sandbox.checkout(Repo, sandbox: false)

      try do
        fun.()
      after
        Sandbox.checkin(Repo)
      end
    end)
  end

  defp await_lock_waiters!(expected, timeout) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_await_lock_waiters!(expected, deadline)
  end

  defp do_await_lock_waiters!(expected, deadline) do
    [[count]] =
      Repo.query!("""
      SELECT count(*)
      FROM pg_stat_activity
      WHERE wait_event_type = 'Lock'
      """).rows

    cond do
      count >= expected ->
        :ok

      System.monotonic_time(:millisecond) >= deadline ->
        flunk("expected #{expected} lock waiters, found #{count}")

      true ->
        Process.sleep(10)
        do_await_lock_waiters!(expected, deadline)
    end
  end

  defp with_catalog(fun) do
    :ok = Sandbox.checkout(Repo, sandbox: false)
    user = user_fixture()
    organization = organization_fixture()
    organization_membership_fixture(user, organization, %{role: "admin"})
    scope = Accounts.scope_for_user(user, organization.id)

    {:ok, manufacturer} =
      Catalog.create_manufacturer(
        scope,
        %{name: "Concurrency Vendor", lifecycle_state: "active"},
        %{slug: "concurrency-vendor"}
      )

    {:ok, hardware_type} =
      Catalog.create_hardware_type(
        scope,
        %{name: "Concurrency Hardware", lifecycle_state: "active"},
        %{manufacturer_id: manufacturer.id, model: "HW-1", device_class: "server"}
      )

    try do
      fun.(scope, hardware_type)
    after
      Repo.delete!(organization)
      Repo.delete!(user)
      Sandbox.checkin(Repo)
    end
  end

  defp module_fixture(scope, module_type, name) do
    {:ok, module} =
      Catalog.create_module(
        scope,
        module_type,
        %{name: name, lifecycle_state: "active"},
        %{status: "active"}
      )

    module
  end

  defp module_type_fixture(scope, hardware_type, model) do
    {:ok, module_type} =
      Catalog.create_module_type(
        scope,
        %{name: "Concurrency Module #{model}", lifecycle_state: "active"},
        %{
          manufacturer_id: hardware_type.manufacturer_id,
          model: model,
          module_class: "line_card"
        }
      )

    {:ok, _revision} = Catalog.create_module_type_revision(scope, module_type, %{})
    module_type
  end
end
