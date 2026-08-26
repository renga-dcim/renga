defmodule RengaWeb.CatalogLiveTest do
  use RengaWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Renga.AccountsFixtures
  import Renga.InventoryFixtures

  alias Renga.Catalog

  setup %{conn: conn} do
    user = user_fixture()
    organization = organization_fixture()
    organization_membership_fixture(user, organization, %{role: "admin"})
    scope = Renga.Accounts.scope_for_user(user, organization.id)

    conn =
      conn
      |> log_in_user(user)
      |> put_session(:current_organization_id, organization.id)

    %{conn: conn, organization: organization, scope: scope}
  end

  test "renders useful empty states", %{conn: conn} do
    {:ok, manufacturers, _html} = live(conn, "/dcim/manufacturers")
    assert has_element?(manufacturers, "#catalog-browser")
    assert has_element?(manufacturers, "#manufacturers-empty")

    {:ok, hardware_types, _html} = live(conn, "/dcim/hardware-types")
    assert has_element?(hardware_types, "#hardware-types-empty")
  end

  test "lists catalog identity and links to type detail", %{conn: conn, scope: scope} do
    {:ok, manufacturer} = manufacturer_fixture(scope, "Acme Systems", "acme-systems")
    {:ok, hardware_type} = hardware_type_fixture(scope, manufacturer, "RS-42", "server")

    {:ok, manufacturers, _html} = live(conn, "/dcim/manufacturers")
    assert has_element?(manufacturers, "#manufacturer-#{manufacturer.id}", "Acme Systems")

    {:ok, types, _html} = live(conn, "/dcim/hardware-types")
    assert has_element?(types, "#hardware-type-#{hardware_type.id}", "Acme Systems RS-42")

    assert has_element?(
             types,
             "#hardware-type-#{hardware_type.id} a[href='/dcim/hardware-types/#{hardware_type.id}']"
           )
  end

  test "shows revision dimensions, specifications, pinning, and grouped templates", %{
    conn: conn,
    scope: scope
  } do
    {:ok, manufacturer} = manufacturer_fixture(scope, "Acme Systems", "acme-systems")
    {:ok, hardware_type} = hardware_type_fixture(scope, manufacturer, "RS-42", "server")

    {:ok, revision} =
      Catalog.create_hardware_type_revision(
        scope,
        hardware_type,
        %{
          part_number: "PN-RS42",
          height_units: 2,
          width_mm: "482.60",
          depth_mm: "800.00",
          weight_kg: "18.500",
          airflow: "front_to_rear",
          specifications: %{"cpu_sockets" => 2, "management" => "BMC"}
        },
        [
          %{kind: "interface", name: "eth0", label: "Management", position: "rear"},
          %{kind: "interface", name: "eth1", required: false},
          %{kind: "module_bay", name: "PSU1", position: "rear-left"}
        ]
      )

    {:ok, view, _html} = live(conn, "/dcim/hardware-types/#{hardware_type.id}")

    assert has_element?(view, "#hardware-type-identity", "Acme Systems")
    assert has_element?(view, "#hardware-type-device-class", "Server")
    assert has_element?(view, "#revision-#{revision.revision}", "Immutable revision pin")
    assert has_element?(view, "#revision-#{revision.revision}-dimensions", "482.60 mm")
    assert has_element?(view, "#revision-#{revision.revision}-specifications", "Cpu sockets")
    assert has_element?(view, "#revision-#{revision.revision}-specifications", "BMC")
    assert has_element?(view, "#revision-#{revision.revision}-templates-interface", "Management")
    assert has_element?(view, "#revision-#{revision.revision}-templates-module_bay", "PSU1")
  end

  test "tenant catalog lists exclude foreign records and foreign detail raises", %{
    conn: conn,
    scope: scope
  } do
    {:ok, local_manufacturer} = manufacturer_fixture(scope, "Local Vendor", "local-vendor")
    {:ok, local_type} = hardware_type_fixture(scope, local_manufacturer, "LOCAL-1", "server")

    foreign_user = user_fixture()
    foreign_organization = organization_fixture()
    organization_membership_fixture(foreign_user, foreign_organization, %{role: "admin"})
    foreign_scope = Renga.Accounts.scope_for_user(foreign_user, foreign_organization.id)

    {:ok, foreign_manufacturer} =
      manufacturer_fixture(foreign_scope, "Foreign Vendor", "foreign-vendor")

    {:ok, foreign_type} =
      hardware_type_fixture(foreign_scope, foreign_manufacturer, "SECRET-1", "server")

    {:ok, manufacturers, _html} = live(conn, "/dcim/manufacturers")
    assert has_element?(manufacturers, "#manufacturer-#{local_manufacturer.id}")
    refute has_element?(manufacturers, "#manufacturer-#{foreign_manufacturer.id}")

    {:ok, types, _html} = live(conn, "/dcim/hardware-types")
    assert has_element?(types, "#hardware-type-#{local_type.id}")
    refute has_element?(types, "#hardware-type-#{foreign_type.id}")

    assert_raise Ecto.NoResultsError, fn ->
      live(conn, "/dcim/hardware-types/#{foreign_type.id}")
    end
  end

  test "organization viewers have read-only catalog access", %{
    organization: organization,
    scope: scope
  } do
    viewer = user_fixture()
    organization_membership_fixture(viewer, organization, %{role: "viewer"})
    {:ok, manufacturer} = manufacturer_fixture(scope, "Readable Vendor", "readable-vendor")
    {:ok, hardware_type} = hardware_type_fixture(scope, manufacturer, "VIEW-1", "switch")

    viewer_conn =
      build_conn()
      |> log_in_user(viewer)
      |> put_session(:current_organization_id, organization.id)

    {:ok, view, _html} = live(viewer_conn, "/dcim/hardware-types/#{hardware_type.id}")
    assert has_element?(view, "#hardware-type-detail-#{hardware_type.id}")
    refute has_element?(view, "#hardware-type-detail-#{hardware_type.id} form")
    refute has_element?(view, "#hardware-type-detail-#{hardware_type.id} [phx-click]")
  end

  defp manufacturer_fixture(scope, name, slug) do
    Catalog.create_manufacturer(
      scope,
      %{name: name, lifecycle_state: "active"},
      %{slug: slug, description: "#{name} catalog identity"}
    )
  end

  defp hardware_type_fixture(scope, manufacturer, model, device_class) do
    Catalog.create_hardware_type(
      scope,
      %{name: "#{manufacturer.id}-hardware-#{model}", lifecycle_state: "active"},
      %{
        manufacturer_id: manufacturer.id,
        model: model,
        device_class: device_class,
        description: "#{model} hardware definition"
      }
    )
  end
end
