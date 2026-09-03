defmodule RengaWeb.ResourceHardwareLiveTest do
  use RengaWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Renga.AccountsFixtures
  import Renga.InventoryFixtures

  alias Renga.Accounts
  alias Renga.Catalog
  alias Renga.Catalog.ActualComponent
  alias Renga.Catalog.ActualComponentEvidenceMatch
  alias Renga.Inventory
  alias Renga.Repo

  setup %{conn: conn} do
    user = user_fixture()
    organization = organization_fixture()
    membership = organization_membership_fixture(user, organization, %{role: "admin"})
    scope = Accounts.scope_for_user(user, organization.id)

    conn =
      conn
      |> log_in_user(user)
      |> put_session(:current_organization_id, organization.id)

    {:ok, resource} =
      Inventory.create_resource(scope, %{kind: "server", name: "hardware-ui-server"})

    %{
      conn: conn,
      membership: membership,
      organization: organization,
      resource: resource,
      scope: scope
    }
  end

  test "assigns a pinned hardware type and renders materialized expectations", %{
    conn: conn,
    resource: resource,
    scope: scope
  } do
    hardware_type =
      hardware_type_fixture(scope, "UI-SERVER", [
        %{kind: "cpu", name: "CPU 1", position: "CPU1"},
        %{kind: "interface", name: "Management", position: "eth0"}
      ])

    {:ok, view, _html} = live(conn, ~p"/inventory/resources/#{resource.id}/hardware")

    assert has_element?(view, "#resource-hardware")
    assert has_element?(view, "#hardware-assignment-form")
    assert has_element?(view, "#expected-components-list", "No component expectations")

    view
    |> form("#hardware-assignment-form", hardware: %{hardware_type_id: hardware_type.id})
    |> render_submit()

    assignment = Catalog.get_hardware_assignment(scope, resource.id)
    assert assignment.hardware_type_id == hardware_type.id
    assert assignment.catalog_type_revision.revision == 1
    assert has_element?(view, "#hardware-assignment", "UI-SERVER")
    assert has_element?(view, "#expected-components-list", "CPU 1")
    assert has_element?(view, "#expected-components-list", "Management")
    assert has_element?(view, "#hardware-assignment-clear")
  end

  test "labels asset-suppressed expectations instead of presenting them as required", %{
    conn: conn,
    resource: resource,
    scope: scope
  } do
    manufacturer = manufacturer_fixture(scope, "suppressed-ui")

    {:ok, hardware_type} =
      Catalog.create_hardware_type(
        scope,
        %{name: "suppressed-ui-type", lifecycle_state: "active"},
        %{manufacturer_id: manufacturer.id, model: "SUPPRESSED-UI", device_class: "server"}
      )

    {:ok, revision} =
      Catalog.create_hardware_type_revision(scope, hardware_type, %{}, [
        %{kind: "cpu", name: "CPU 1", position: "CPU1"}
      ])

    {:ok, _assignment} = Catalog.assign_hardware_type(scope, resource.id, hardware_type.id)
    template = List.first(revision.component_templates)

    assert {:ok, _exception} =
             Catalog.put_expected_component_exception(scope, resource.id, %{
               action: "suppress",
               component_template_id: template.id
             })

    expected = Enum.find(Catalog.list_expected_components(scope, resource.id), & &1.suppressed)
    {:ok, view, _html} = live(conn, ~p"/inventory/resources/#{resource.id}/hardware")

    assert has_element?(view, "#expected-component-#{expected.id}", "suppressed for this asset")
    refute has_element?(view, "#expected-component-#{expected.id}", "required")
  end

  test "unsupported resources expose no hardware assignment controls", %{
    conn: conn,
    scope: scope
  } do
    {:ok, vm} = Inventory.create_resource(scope, %{kind: "vm", name: "unsupported-vm"})
    hardware_type = hardware_type_fixture(scope, "VM-INVALID", [])

    {:ok, view, _html} = live(conn, ~p"/inventory/resources/#{vm.id}/hardware")

    assert has_element?(view, "#hardware-unsupported")
    refute has_element?(view, "#hardware-assignment-form")

    render_hook(view, "assign_hardware_type", %{
      "hardware" => %{"hardware_type_id" => hardware_type.id}
    })

    assert is_nil(Catalog.get_hardware_assignment(scope, vm.id))
    assert has_element?(view, "#flash-error", "does not support hardware assignments")
  end

  test "shows desired and current module state separately from inventory-only parts", %{
    conn: conn,
    resource: resource,
    scope: scope
  } do
    module_type = module_type_fixture(scope, "LINE-CARD-48")

    assert {:ok, bay} =
             Catalog.create_module_bay(
               scope,
               resource.id,
               %{name: "slot-1", label: "Expansion slot 1", position: "rear"},
               [module_type.id]
             )

    assert {:ok, _desired} =
             Catalog.put_desired_module_assignment(scope, bay.id, module_type.id)

    assert {:ok, module} =
             Catalog.create_module(
               scope,
               module_type,
               %{name: "line-card-serial-1", lifecycle_state: "active"},
               %{serial_number: "LC-SN-1", status: "active"}
             )

    assert {:ok, _installation} = Catalog.install_module(scope, bay.id, module.id)

    assert {:ok, _item} =
             Catalog.create_inventory_item(scope, resource.id, %{
               name: "Cooling fan 1",
               kind: "fan",
               status: "installed",
               position: "fan-1"
             })

    {:ok, view, _html} = live(conn, ~p"/inventory/resources/#{resource.id}/hardware")

    assert has_element?(view, "#module-bay-#{bay.id}", "Expansion slot 1")
    assert has_element?(view, "#module-bay-#{bay.id}", "LINE-CARD-48")
    assert has_element?(view, "#module-bay-#{bay.id}", "LC-SN-1")
    assert has_element?(view, "#module-bay-#{bay.id}", "1 installation events")
    assert has_element?(view, "#inventory-items-list", "Cooling fan 1")
    assert has_element?(view, "#inventory-items-list", "Resource root")
  end

  test "distinguishes canonical components from their current source evidence", %{
    conn: conn,
    resource: resource,
    scope: scope
  } do
    {:ok, source} = Inventory.create_source(scope, %{kind: "host_agent", name: "evidence-agent"})

    {:ok, observation} =
      Inventory.create_observation(scope, source.id, %{
        observation_id: "hardware-source-evidence",
        observed_at: ~U[2026-08-21 09:30:00.000000Z],
        payload: %{}
      })

    assert {:ok, evidence} =
             Inventory.create_component_evidence(
               scope,
               source.id,
               observation.id,
               resource.id,
               %{
                 kind: "cpu",
                 source_local_id: "cpu-1",
                 name: "Processor 1",
                 slot: "CPU1"
               }
             )

    actual =
      %ActualComponent{
        organization_id: scope.organization_id,
        owner_resource_id: resource.id
      }
      |> ActualComponent.changeset(%{
        kind: "cpu",
        name: "Processor 1",
        slot: "CPU1",
        first_observed_at: observation.observed_at,
        last_observed_at: observation.observed_at
      })
      |> Repo.insert!()

    match =
      %ActualComponentEvidenceMatch{
        organization_id: scope.organization_id,
        owner_resource_id: resource.id,
        actual_component_id: actual.id,
        component_evidence_id: evidence.id
      }
      |> ActualComponentEvidenceMatch.changeset(%{match_strategy: "discovered"})
      |> Repo.insert!()

    {:ok, view, _html} = live(conn, ~p"/inventory/resources/#{resource.id}/hardware")

    assert has_element?(view, "#actual-component-#{actual.id}", "Processor 1")

    assert has_element?(
             view,
             "#component-evidence-match-#{match.id}",
             "evidence-agent · discovered · 2026-08-21 09:30 UTC"
           )
  end

  test "viewer can read hardware but cannot forge assignment mutations", %{
    organization: organization,
    resource: resource,
    scope: scope
  } do
    hardware_type = hardware_type_fixture(scope, "VIEWER-TYPE", [])
    viewer = user_fixture()
    organization_membership_fixture(viewer, organization, %{role: "viewer"})

    viewer_conn =
      build_conn()
      |> log_in_user(viewer)
      |> put_session(:current_organization_id, organization.id)

    {:ok, view, _html} = live(viewer_conn, ~p"/inventory/resources/#{resource.id}/hardware")
    assert has_element?(view, "#hardware-read-only")
    refute has_element?(view, "#hardware-assignment-form")

    render_hook(view, "assign_hardware_type", %{
      "hardware" => %{"hardware_type_id" => hardware_type.id}
    })

    assert is_nil(Catalog.get_hardware_assignment(scope, resource.id))
    assert has_element?(view, "#flash-error", "not allowed")
  end

  test "organization members can assign hardware types", %{
    organization: organization,
    resource: resource,
    scope: scope
  } do
    hardware_type = hardware_type_fixture(scope, "MEMBER-TYPE", [])
    member = user_fixture()
    organization_membership_fixture(member, organization, %{role: "member"})

    member_conn =
      build_conn()
      |> log_in_user(member)
      |> put_session(:current_organization_id, organization.id)

    {:ok, view, _html} = live(member_conn, ~p"/inventory/resources/#{resource.id}/hardware")
    assert has_element?(view, "#hardware-assignment-form")

    view
    |> form("#hardware-assignment-form", hardware: %{hardware_type_id: hardware_type.id})
    |> render_submit()

    assert Catalog.get_hardware_assignment(scope, resource.id).hardware_type_id ==
             hardware_type.id
  end

  test "rejects a hardware type ID from another organization", %{
    conn: conn,
    resource: resource,
    scope: scope
  } do
    other_user = user_fixture()
    other_organization = organization_fixture()
    organization_membership_fixture(other_user, other_organization, %{role: "admin"})
    other_scope = Accounts.scope_for_user(other_user, other_organization.id)
    foreign_type = hardware_type_fixture(other_scope, "FOREIGN-TYPE", [])

    {:ok, view, _html} = live(conn, ~p"/inventory/resources/#{resource.id}/hardware")

    render_hook(view, "assign_hardware_type", %{
      "hardware" => %{"hardware_type_id" => foreign_type.id}
    })

    assert is_nil(Catalog.get_hardware_assignment(scope, resource.id))
    assert has_element?(view, "#flash-error", "this organization")
  end

  test "explains when a selected hardware type has no finalized revision", %{
    conn: conn,
    resource: resource,
    scope: scope
  } do
    manufacturer = manufacturer_fixture(scope, "unfinished")

    assert {:ok, hardware_type} =
             Catalog.create_hardware_type(
               scope,
               %{name: "unfinished-type", lifecycle_state: "active"},
               %{manufacturer_id: manufacturer.id, model: "UNFINISHED", device_class: "server"}
             )

    {:ok, view, _html} = live(conn, ~p"/inventory/resources/#{resource.id}/hardware")

    view
    |> form("#hardware-assignment-form", hardware: %{hardware_type_id: hardware_type.id})
    |> render_submit()

    assert is_nil(Catalog.get_hardware_assignment(scope, resource.id))
    assert has_element?(view, "#flash-error", "no finalized revision")
  end

  test "foreign resource detail is not visible", %{conn: conn} do
    other_user = user_fixture()
    other_organization = organization_fixture()
    organization_membership_fixture(other_user, other_organization, %{role: "admin"})
    other_scope = Accounts.scope_for_user(other_user, other_organization.id)
    {:ok, foreign} = Inventory.create_resource(other_scope, %{kind: "server", name: "foreign"})

    assert_raise Ecto.NoResultsError, fn ->
      live(conn, ~p"/inventory/resources/#{foreign.id}/hardware")
    end
  end

  defp hardware_type_fixture(scope, model, templates) do
    manufacturer = manufacturer_fixture(scope, "hardware-#{model}")

    {:ok, hardware_type} =
      Catalog.create_hardware_type(
        scope,
        %{name: "hardware-type-#{model}", lifecycle_state: "active"},
        %{manufacturer_id: manufacturer.id, model: model, device_class: "server"}
      )

    {:ok, _revision} = Catalog.create_hardware_type_revision(scope, hardware_type, %{}, templates)
    hardware_type
  end

  defp module_type_fixture(scope, model) do
    manufacturer = manufacturer_fixture(scope, "module-#{model}")

    {:ok, module_type} =
      Catalog.create_module_type(
        scope,
        %{name: "module-type-#{model}", lifecycle_state: "active"},
        %{manufacturer_id: manufacturer.id, model: model, module_class: "line_card"}
      )

    {:ok, _revision} = Catalog.create_module_type_revision(scope, module_type, %{})
    module_type
  end

  defp manufacturer_fixture(scope, suffix) do
    slug = suffix |> String.downcase() |> String.replace(~r/[^a-z0-9]+/, "-")

    {:ok, manufacturer} =
      Catalog.create_manufacturer(
        scope,
        %{name: "Vendor #{suffix}", lifecycle_state: "active"},
        %{slug: slug}
      )

    manufacturer
  end
end
