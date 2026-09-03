defmodule Renga.CatalogModuleTest do
  use Renga.DataCase, async: true

  import Renga.AccountsFixtures
  import Renga.InventoryFixtures

  alias Renga.Accounts
  alias Renga.Catalog
  alias Renga.Catalog.CurrentModuleInstallation
  alias Renga.Catalog.DesiredModuleAssignment
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

  test "members manage modules and bays through the catalog boundary", %{
    scope: scope,
    membership: membership
  } do
    module_type = module_type_fixture(scope, "LC-48")
    {:ok, _revision} = Catalog.create_module_type_revision(scope, module_type, %{})
    owner = resource_fixture(scope, "managed-bay-owner")
    module = module_fixture(scope, module_type, "Managed module")

    {:ok, bay} =
      Catalog.create_module_bay(scope, owner.id, %{name: "Managed bay"}, [module_type.id])

    {:ok, _membership} = Accounts.update_organization_membership(membership, %{role: "member"})

    assert {:ok, member_module} =
             Catalog.create_module(
               scope,
               module_type,
               %{name: "Member module", lifecycle_state: "active"}
             )

    assert {:ok, _member_bay} =
             Catalog.create_module_bay(scope, owner.id, %{name: "Member bay"})

    assert {:ok, desired} =
             Catalog.put_desired_module_assignment(scope, bay.id, module_type.id)

    assert desired.module_type_id == module_type.id
    assert {:ok, installation} = Catalog.install_module(scope, bay.id, module.id)
    assert installation.module_id == module.id
    assert member_module.module_type_id == module_type.id

    assert {:error, :forbidden} =
             Inventory.create_resource(scope, %{kind: "module", name: "Orphan module"})
  end

  test "desired assignments remain separate from current installations", %{scope: scope} do
    desired_type = module_type_fixture(scope, "DESIRED")
    installed_type = module_type_fixture(scope, "INSTALLED")
    {:ok, _revision} = Catalog.create_module_type_revision(scope, desired_type, %{})
    {:ok, _revision} = Catalog.create_module_type_revision(scope, installed_type, %{})
    owner = resource_fixture(scope, "separate-state-owner")

    {:ok, bay} =
      Catalog.create_module_bay(scope, owner.id, %{name: "Slot 1"}, [
        desired_type.id,
        installed_type.id
      ])

    installed_module = module_fixture(scope, installed_type, "Installed module")

    assert {:ok, desired} =
             Catalog.put_desired_module_assignment(scope, bay.id, desired_type.id, %{
               metadata: %{"reason" => "capacity plan"}
             })

    assert {:ok, current} =
             Catalog.install_module(scope, bay.id, installed_module.id, %{
               occurred_at: ~U[2026-08-25 12:00:00.000Z],
               metadata: %{"source" => "operator"}
             })

    assert desired.module_type_id == desired_type.id
    assert current.module_type_id == installed_type.id
    assert Catalog.get_desired_module_assignment(scope, bay.id).module_type_id == desired_type.id
    assert Catalog.get_current_module_installation(scope, bay.id).module_id == installed_module.id
  end

  test "catalog reconciler service scopes can update current but not desired state", %{
    scope: scope,
    organization: organization
  } do
    module_type = module_type_fixture(scope, "RECONCILED")
    {:ok, _revision} = Catalog.create_module_type_revision(scope, module_type, %{})
    owner = resource_fixture(scope, "reconciled-owner")
    {:ok, bay} = Catalog.create_module_bay(scope, owner.id, %{name: "Slot 1"}, [module_type.id])
    module = module_fixture(scope, module_type, "Reconciled module")
    reconciler_scope = Accounts.scope_for(organization, %{roles: ["catalog_reconciler"]})

    assert {:error, :forbidden} =
             Catalog.put_desired_module_assignment(reconciler_scope, bay.id, module_type.id)

    assert {:ok, installation} = Catalog.install_module(reconciler_scope, bay.id, module.id)
    assert installation.module_id == module.id

    assert [%{action: "installed", actor_user_id: nil}] =
             Catalog.list_module_installation_events(reconciler_scope, bay.id)
  end

  test "install, replacement, and removal are atomic and retain ordered history", %{scope: scope} do
    module_type = module_type_fixture(scope, "HISTORY")
    {:ok, _revision} = Catalog.create_module_type_revision(scope, module_type, %{})
    owner = resource_fixture(scope, "history-owner")
    {:ok, bay} = Catalog.create_module_bay(scope, owner.id, %{name: "Slot 1"}, [module_type.id])
    first = module_fixture(scope, module_type, "First module")
    second = module_fixture(scope, module_type, "Second module")
    occurred_at = ~U[2026-08-25 12:00:00.000Z]

    assert {:ok, _installation} =
             Catalog.install_module(scope, bay.id, first.id, %{
               occurred_at: occurred_at
             })

    assert {:ok, replacement} =
             Catalog.install_module(scope, bay.id, second.id, %{
               occurred_at: occurred_at
             })

    assert replacement.module_id == second.id

    assert {:ok, nil} =
             Catalog.remove_module(scope, bay.id, %{
               occurred_at: occurred_at
             })

    refute Catalog.get_current_module_installation(scope, bay.id)

    assert Enum.map(Catalog.list_module_installation_events(scope, bay.id), fn event ->
             {event.action, event.module_id}
           end) == [
             {"installed", first.id},
             {"removed", first.id},
             {"installed", second.id},
             {"removed", second.id}
           ]
  end

  test "installation history retains transition order when event times are backdated", %{
    scope: scope
  } do
    module_type = module_type_fixture(scope, "BACKDATED-HISTORY")
    {:ok, _revision} = Catalog.create_module_type_revision(scope, module_type, %{})
    owner = resource_fixture(scope, "backdated-history-owner")
    {:ok, bay} = Catalog.create_module_bay(scope, owner.id, %{name: "Slot 1"}, [module_type.id])
    first = module_fixture(scope, module_type, "Original module")
    second = module_fixture(scope, module_type, "Replacement module")

    assert {:ok, _installation} =
             Catalog.install_module(scope, bay.id, first.id, %{
               occurred_at: ~U[2026-08-25 14:00:00.000Z]
             })

    assert {:ok, _replacement} =
             Catalog.install_module(scope, bay.id, second.id, %{
               occurred_at: ~U[2026-08-25 13:00:00.000Z]
             })

    assert Enum.map(Catalog.list_module_installation_events(scope, bay.id), fn event ->
             {event.action, event.module_id}
           end) == [
             {"installed", first.id},
             {"removed", first.id},
             {"installed", second.id}
           ]
  end

  test "disabled, incompatible, and occupied bays reject invalid changes", %{scope: scope} do
    compatible_type = module_type_fixture(scope, "COMPATIBLE")
    incompatible_type = module_type_fixture(scope, "INCOMPATIBLE")
    {:ok, _revision} = Catalog.create_module_type_revision(scope, compatible_type, %{})
    {:ok, _revision} = Catalog.create_module_type_revision(scope, incompatible_type, %{})
    owner = resource_fixture(scope, "validation-owner")

    {:ok, bay} =
      Catalog.create_module_bay(scope, owner.id, %{name: "Slot 1"}, [compatible_type.id])

    compatible_module = module_fixture(scope, compatible_type, "Compatible module")
    incompatible_module = module_fixture(scope, incompatible_type, "Incompatible module")

    {:ok, unavailable_module} =
      Catalog.create_module(
        scope,
        compatible_type,
        %{name: "Failed module", lifecycle_state: "active"},
        %{status: "failed"}
      )

    assert {:error, :incompatible_module_type} =
             Catalog.put_desired_module_assignment(scope, bay.id, incompatible_type.id)

    assert {:error, :incompatible_module_type} =
             Catalog.install_module(scope, bay.id, incompatible_module.id)

    assert {:error, :module_not_installable} =
             Catalog.install_module(scope, bay.id, unavailable_module.id)

    assert {:ok, _desired} =
             Catalog.put_desired_module_assignment(scope, bay.id, compatible_type.id)

    assert {:ok, _current} = Catalog.install_module(scope, bay.id, compatible_module.id)

    {:ok, second_bay} =
      Catalog.create_module_bay(scope, owner.id, %{name: "Slot 2"}, [compatible_type.id])

    assert {:error, :module_already_installed} =
             Catalog.install_module(scope, second_bay.id, compatible_module.id)

    assert {:error, :compatibility_in_use} =
             Catalog.set_module_bay_compatible_types(scope, bay, [])

    assert {:error, :module_bay_in_use} =
             Catalog.update_module_bay(scope, bay, %{status: "disabled"})

    assert {:ok, nil} = Catalog.clear_desired_module_assignment(scope, bay.id)
    assert {:ok, nil} = Catalog.remove_module(scope, bay.id)
    assert {:ok, disabled} = Catalog.update_module_bay(scope, bay, %{status: "disabled"})

    assert {:error, :module_bay_disabled} =
             Catalog.put_desired_module_assignment(scope, disabled.id, compatible_type.id)

    assert {:error, :module_bay_disabled} =
             Catalog.install_module(scope, disabled.id, compatible_module.id)
  end

  test "database constraints reject incompatible desired and current state", %{scope: scope} do
    compatible_type = module_type_fixture(scope, "DATABASE-COMPATIBLE")
    incompatible_type = module_type_fixture(scope, "DATABASE-INCOMPATIBLE")
    {:ok, _revision} = Catalog.create_module_type_revision(scope, compatible_type, %{})
    {:ok, _revision} = Catalog.create_module_type_revision(scope, incompatible_type, %{})
    owner = resource_fixture(scope, "database-constraint-owner")

    {:ok, bay} =
      Catalog.create_module_bay(scope, owner.id, %{name: "Slot 1"}, [compatible_type.id])

    incompatible_module = module_fixture(scope, incompatible_type, "Database incompatible module")

    error =
      assert_raise Postgrex.Error, fn ->
        Repo.transaction(fn ->
          %DesiredModuleAssignment{
            organization_id: scope.organization_id,
            module_bay_id: bay.id,
            module_type_id: incompatible_type.id,
            confirmed_by_user_id: scope.user.id
          }
          |> Repo.insert!()

          Repo.query!("SET CONSTRAINTS desired_module_assignments_compatibility_fkey IMMEDIATE")
        end)
      end

    assert error.postgres.constraint == "desired_module_assignments_compatibility_fkey"

    error =
      assert_raise Postgrex.Error, fn ->
        Repo.transaction(fn ->
          %CurrentModuleInstallation{
            organization_id: scope.organization_id,
            module_bay_id: bay.id,
            module_id: incompatible_module.id,
            module_type_id: compatible_type.id,
            installed_at: Renga.Time.utc_now_ms()
          }
          |> Repo.insert!()

          Repo.query!("SET CONSTRAINTS current_module_installations_module_fkey IMMEDIATE")
        end)
      end

    assert error.postgres.constraint == "current_module_installations_module_fkey"
  end

  test "module containment rejects direct and transitive cycles", %{scope: scope} do
    module_type = module_type_fixture(scope, "NESTED")
    {:ok, _revision} = Catalog.create_module_type_revision(scope, module_type, %{})
    first = module_fixture(scope, module_type, "First nested module")
    second = module_fixture(scope, module_type, "Second nested module")
    third = module_fixture(scope, module_type, "Third nested module")

    {:ok, first_bay} =
      Catalog.create_module_bay(scope, first.resource_id, %{name: "First child"}, [module_type.id])

    {:ok, second_bay} =
      Catalog.create_module_bay(scope, second.resource_id, %{name: "Second child"}, [
        module_type.id
      ])

    {:ok, third_bay} =
      Catalog.create_module_bay(scope, third.resource_id, %{name: "Third child"}, [module_type.id])

    assert {:error, :hierarchy_cycle} = Catalog.install_module(scope, first_bay.id, first.id)
    assert {:ok, _installation} = Catalog.install_module(scope, first_bay.id, second.id)
    assert {:ok, _installation} = Catalog.install_module(scope, second_bay.id, third.id)
    assert {:error, :hierarchy_cycle} = Catalog.install_module(scope, third_bay.id, first.id)
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
end
