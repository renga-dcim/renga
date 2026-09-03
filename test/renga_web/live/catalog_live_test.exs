defmodule RengaWeb.CatalogLiveTest do
  use RengaWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Renga.AccountsFixtures
  import Renga.InventoryFixtures

  alias Renga.Catalog
  alias Renga.Inventory

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
    assert has_element?(manufacturers, "#new-manufacturer-form")

    {:ok, hardware_types, _html} = live(conn, "/dcim/hardware-types")
    assert has_element?(hardware_types, "#hardware-types-empty")
    assert has_element?(hardware_types, "#new-hardware-type-form")

    {:ok, module_types, _html} = live(conn, "/dcim/module-types")
    assert has_element?(module_types, "#module-types-empty")
    assert has_element?(module_types, "#new-module-type-form")
  end

  test "organization managers author manufacturer, hardware, and module identities", %{
    conn: conn,
    scope: scope
  } do
    {:ok, manufacturers, _html} = live(conn, "/dcim/manufacturers")

    redirect =
      manufacturers
      |> form("#new-manufacturer-form",
        manufacturer: %{
          name: "Authoring Vendor",
          slug: "authoring-vendor",
          description: "Created from the catalog"
        }
      )
      |> render_submit()

    assert {"/dcim/manufacturers", _flash} = assert_redirect(manufacturers)
    {:ok, manufacturer_view, _html} = follow_redirect(redirect, conn)
    assert has_element?(manufacturer_view, "#manufacturers-list", "Authoring Vendor")
    [manufacturer] = Catalog.list_manufacturers(scope)

    {:ok, hardware_types, _html} = live(conn, "/dcim/hardware-types")

    hardware_redirect =
      hardware_types
      |> form("#new-hardware-type-form",
        hardware_type: %{
          manufacturer_id: manufacturer.id,
          model: "AUTHOR-SERVER",
          device_class: "server",
          description: "Authored server"
        }
      )
      |> render_submit()

    {hardware_path, _flash} = assert_redirect(hardware_types)
    assert hardware_path =~ "/dcim/hardware-types/"
    {:ok, hardware_detail, _html} = follow_redirect(hardware_redirect, conn)
    assert has_element?(hardware_detail, "[id^='hardware-type-detail-']", "AUTHOR-SERVER")

    {:ok, module_types, _html} = live(conn, "/dcim/module-types")

    module_redirect =
      module_types
      |> form("#new-module-type-form",
        module_type: %{
          manufacturer_id: manufacturer.id,
          model: "AUTHOR-LINE-CARD",
          module_class: "line_card",
          description: "Authored module"
        }
      )
      |> render_submit()

    {module_path, _flash} = assert_redirect(module_types)
    assert module_path =~ "/dcim/module-types/"
    {:ok, module_detail, _html} = follow_redirect(module_redirect, conn)
    assert has_element?(module_detail, "[id^='module-type-detail-']", "AUTHOR-LINE-CARD")
    assert has_element?(module_detail, "#module-type-module-class", "Line card")
  end

  test "catalog authoring reports validation errors without creating partial resources", %{
    conn: conn,
    scope: scope
  } do
    {:ok, view, _html} = live(conn, "/dcim/manufacturers")

    view
    |> form("#new-manufacturer-form",
      manufacturer: %{name: "Invalid Vendor", slug: "Not a slug!", description: ""}
    )
    |> render_submit()

    assert has_element?(view, "#flash-error", "has invalid format")
    assert has_element?(view, "#new-manufacturer-form input[value='Invalid Vendor']")
    assert Catalog.list_manufacturers(scope) == []
    assert Renga.Inventory.list_resources(scope) == []
  end

  test "catalog type submission resolves manufacturers from current tenant data", %{
    conn: conn,
    scope: scope
  } do
    {:ok, view, _html} = live(conn, "/dcim/hardware-types")
    {:ok, manufacturer} = manufacturer_fixture(scope, "Fresh Vendor", "fresh-vendor")

    render_hook(view, "create_hardware_type", %{
      "hardware_type" => %{
        "manufacturer_id" => manufacturer.id,
        "model" => "  FRESH-1  ",
        "device_class" => "server",
        "description" => ""
      }
    })

    assert {_path, _flash} = assert_redirect(view)
    [hardware_type] = Catalog.list_hardware_types(scope)
    assert hardware_type.model == "FRESH-1"
    assert hardware_type.resource.name == "Fresh Vendor FRESH-1"
  end

  test "catalog type submission rejects a foreign manufacturer without partial writes", %{
    conn: conn,
    scope: scope
  } do
    {:ok, view, _html} = live(conn, "/dcim/hardware-types")
    foreign_user = user_fixture()
    foreign_organization = organization_fixture()
    organization_membership_fixture(foreign_user, foreign_organization, %{role: "admin"})
    foreign_scope = Renga.Accounts.scope_for_user(foreign_user, foreign_organization.id)

    {:ok, foreign_manufacturer} =
      manufacturer_fixture(foreign_scope, "Foreign Vendor", "foreign-vendor")

    render_hook(view, "create_hardware_type", %{
      "hardware_type" => %{
        "manufacturer_id" => foreign_manufacturer.id,
        "model" => "FOREIGN-1",
        "device_class" => "server",
        "description" => ""
      }
    })

    assert has_element?(view, "#flash-error", "manufacturer")
    assert Catalog.list_hardware_types(scope) == []
    assert Inventory.list_resources(scope) == []
  end

  test "organization members can author catalog identities", %{
    organization: organization
  } do
    member = user_fixture()
    organization_membership_fixture(member, organization, %{role: "member"})

    member_conn =
      build_conn()
      |> log_in_user(member)
      |> put_session(:current_organization_id, organization.id)

    {:ok, view, _html} = live(member_conn, "/dcim/manufacturers")
    assert has_element?(view, "#new-manufacturer-form")

    view
    |> form("#new-manufacturer-form",
      manufacturer: %{name: "Member Vendor", slug: "member-vendor", description: ""}
    )
    |> render_submit()

    assert {"/dcim/manufacturers", _flash} = assert_redirect(view)
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
          specifications: %{
            "cpu_sockets" => 2,
            "cpu sockets" => 3,
            "management" => "BMC",
            "enabled_string" => "true",
            "enabled_boolean" => true,
            "unset" => nil
          }
        },
        [
          %{
            kind: "interface",
            name: "eth0",
            label: "Management",
            position: "rear",
            description: "Dedicated management port",
            attributes: %{"speed_mbps" => 1000, "supported_vlans" => Enum.to_list(1..25)}
          },
          %{kind: "interface", name: "eth1", required: false},
          %{kind: "module_bay", name: "PSU1", position: "rear-left"}
        ]
      )

    {:ok, view, _html} = live(conn, "/dcim/hardware-types/#{hardware_type.id}")

    assert has_element?(view, "#hardware-type-identity", "Acme Systems")
    assert has_element?(view, "#hardware-type-device-class", "Server")
    assert has_element?(view, "#revision-#{revision.revision}", "Immutable revision pin")
    assert has_element?(view, "#revision-#{revision.revision}-dimensions", "482.60 mm")
    assert has_element?(view, "#revision-#{revision.revision}-specifications", "BMC")
    assert has_element?(view, "#revision-#{revision.revision}-specifications", "cpu_sockets")
    assert has_element?(view, "#revision-#{revision.revision}-specifications", "cpu sockets")
    assert has_element?(view, "#revision-#{revision.revision}-specifications", ~s("true"))
    assert has_element?(view, "#revision-#{revision.revision}-specifications", "null")
    assert has_element?(view, "#revision-#{revision.revision}-templates-interface", "Management")
    assert has_element?(view, "#revision-#{revision.revision}-templates-module_bay", "PSU1")

    assert has_element?(
             view,
             "#component-template-#{Enum.find(revision.component_templates, &(&1.name == "eth0")).id}",
             "eth0"
           )

    assert has_element?(
             view,
             "#component-template-#{Enum.find(revision.component_templates, &(&1.name == "eth0")).id}",
             "Dedicated management port"
           )

    assert has_element?(
             view,
             "#component-template-#{Enum.find(revision.component_templates, &(&1.name == "eth0")).id}-attributes",
             "speed_mbps"
           )

    assert has_element?(
             view,
             "#component-template-#{Enum.find(revision.component_templates, &(&1.name == "eth0")).id}-attributes",
             "25"
           )
  end

  test "publishes a typed hardware revision with component templates", %{
    conn: conn,
    scope: scope
  } do
    {:ok, manufacturer} = manufacturer_fixture(scope, "Revision Vendor", "revision-vendor")
    {:ok, hardware_type} = hardware_type_fixture(scope, manufacturer, "REV-1", "server")
    {:ok, view, _html} = live(conn, "/dcim/hardware-types/#{hardware_type.id}")
    view |> element("#add-component-template") |> render_click()

    redirect =
      view
      |> form("#new-revision-form",
        revision: %{
          part_number: "  PN-REV-1  ",
          height_units: "2",
          width_mm: "482.60",
          depth_mm: "800.00",
          weight_kg: "18.500",
          airflow: "front_to_rear",
          specifications: ~s({"cpu_sockets":2,"management":"BMC"}),
          templates: %{
            "0" => %{
              kind: "interface",
              name: "eth0",
              label: "  Management  ",
              position: "rear",
              description: "Management interface",
              required: "true",
              attributes: ~s({"speed_mbps":1000})
            },
            "1" => %{
              kind: "module_bay",
              name: "PSU1",
              label: "Power supply 1",
              position: "rear-left",
              description: "",
              required: "false",
              attributes: "{}"
            }
          }
        }
      )
      |> render_submit()

    assert {path, _flash} = assert_redirect(view)
    assert path == "/dcim/hardware-types/#{hardware_type.id}"
    {:ok, detail, _html} = follow_redirect(redirect, conn)
    assert has_element?(detail, "#revision-1", "PN-REV-1")
    assert has_element?(detail, "#revision-1-templates-interface", "Management")

    [revision] = Catalog.get_hardware_type!(scope, hardware_type.id).revisions
    assert revision.part_number == "PN-REV-1"
    assert revision.height_units == 2
    assert Decimal.equal?(revision.width_mm, Decimal.new("482.60"))
    assert revision.specifications == %{"cpu_sockets" => 2, "management" => "BMC"}

    assert revision.component_templates
           |> Enum.map(&{&1.kind, &1.name, &1.required})
           |> Enum.sort() ==
             [{"interface", "eth0", true}, {"module_bay", "PSU1", false}]

    interface = Enum.find(revision.component_templates, &(&1.name == "eth0"))
    assert interface.label == "Management"
    assert interface.attributes == %{"speed_mbps" => 1000}
  end

  test "component template rows retain identity and values when first and middle rows are removed",
       %{
         conn: conn,
         scope: scope
       } do
    {:ok, manufacturer} = manufacturer_fixture(scope, "Dynamic Vendor", "dynamic-vendor")
    {:ok, hardware_type} = hardware_type_fixture(scope, manufacturer, "DYNAMIC-1", "server")
    {:ok, view, _html} = live(conn, "/dcim/hardware-types/#{hardware_type.id}")

    render_change(view, "validate_revision", %{
      "revision" => %{
        "templates" => %{
          "0" => %{"_persistent_id" => "alpha", "kind" => "interface", "name" => "eth0"},
          "1" => %{"_persistent_id" => "beta", "kind" => "memory", "name" => "DIMM1"},
          "2" => %{"_persistent_id" => "gamma", "kind" => "disk", "name" => "Disk1"}
        }
      }
    })

    assert has_element?(view, "#component-template-field-alpha input[value='eth0']")
    assert has_element?(view, "#component-template-field-gamma input[value='Disk1']")

    view |> element("#remove-component-template-beta") |> render_click()
    refute has_element?(view, "#component-template-field-beta")
    assert has_element?(view, "#component-template-field-alpha input[value='eth0']")
    assert has_element?(view, "#component-template-field-gamma input[value='Disk1']")

    view |> element("#remove-component-template-alpha") |> render_click()
    refute has_element?(view, "#component-template-field-alpha")
    assert has_element?(view, "#component-template-field-gamma input[value='Disk1']")

    view |> element("#remove-component-template-gamma") |> render_click()
    refute has_element?(view, "#component-template-field-gamma")
    assert has_element?(view, "#component-template-fields fieldset")
  end

  test "organization members publish module revisions", %{
    organization: organization,
    scope: scope
  } do
    {:ok, manufacturer} = manufacturer_fixture(scope, "Module Vendor", "module-vendor")
    {:ok, module_type} = module_type_fixture(scope, manufacturer, "MEMBER-MOD", "line_card")
    member = user_fixture()
    organization_membership_fixture(member, organization, %{role: "member"})

    member_conn =
      build_conn()
      |> log_in_user(member)
      |> put_session(:current_organization_id, organization.id)

    {:ok, view, _html} = live(member_conn, "/dcim/module-types/#{module_type.id}")
    assert has_element?(view, "#new-revision-form")

    view
    |> form("#new-revision-form",
      revision: %{
        part_number: "MEMBER-PN",
        specifications: "{}",
        templates: %{
          "0" => %{
            kind: "interface",
            name: "xe-0/0/0",
            required: "true",
            attributes: "{}"
          }
        }
      }
    )
    |> render_submit()

    assert {path, _flash} = assert_redirect(view)
    assert path == "/dcim/module-types/#{module_type.id}"
    [revision] = Catalog.get_module_type!(scope, module_type.id).revisions
    assert revision.part_number == "MEMBER-PN"
    assert Enum.map(revision.component_templates, & &1.name) == ["xe-0/0/0"]
  end

  test "organization owners publish revisions", %{organization: organization, scope: scope} do
    {:ok, manufacturer} = manufacturer_fixture(scope, "Owner Vendor", "owner-vendor")
    {:ok, hardware_type} = hardware_type_fixture(scope, manufacturer, "OWNER-1", "server")
    owner = user_fixture()
    organization_membership_fixture(owner, organization, %{role: "owner"})

    owner_conn =
      build_conn()
      |> log_in_user(owner)
      |> put_session(:current_organization_id, organization.id)

    {:ok, view, _html} = live(owner_conn, "/dcim/hardware-types/#{hardware_type.id}")

    view
    |> form("#new-revision-form",
      revision: %{part_number: "OWNER-PN", specifications: "{}"}
    )
    |> render_submit()

    assert {_path, _flash} = assert_redirect(view)

    assert [%{part_number: "OWNER-PN"}] =
             Catalog.get_hardware_type!(scope, hardware_type.id).revisions
  end

  test "invalid revision JSON preserves input and does not partially publish", %{
    conn: conn,
    scope: scope
  } do
    {:ok, manufacturer} = manufacturer_fixture(scope, "Invalid Vendor", "invalid-vendor")
    {:ok, hardware_type} = hardware_type_fixture(scope, manufacturer, "INVALID-1", "server")
    {:ok, view, _html} = live(conn, "/dcim/hardware-types/#{hardware_type.id}")

    view
    |> form("#new-revision-form",
      revision: %{part_number: "KEEP-ME", specifications: "not json"}
    )
    |> render_submit()

    assert has_element?(view, "#flash-error", "Specifications must contain valid JSON")

    assert has_element?(
             view,
             "#new-revision-form input[name='revision[part_number]'][value='KEEP-ME']"
           )

    assert Catalog.get_hardware_type!(scope, hardware_type.id).revisions == []

    view
    |> form("#new-revision-form",
      revision: %{
        part_number: "KEEP-ME",
        specifications: "{}",
        templates: %{
          "0" => %{kind: "interface", name: "eth0", attributes: "[]"}
        }
      }
    )
    |> render_submit()

    assert has_element?(view, "#flash-error", "Component attributes must be a JSON object")
    assert Catalog.get_hardware_type!(scope, hardware_type.id).revisions == []
  end

  test "revision validation reports field and component errors while typing", %{
    conn: conn,
    scope: scope
  } do
    {:ok, manufacturer} = manufacturer_fixture(scope, "Feedback Vendor", "feedback-vendor")
    {:ok, hardware_type} = hardware_type_fixture(scope, manufacturer, "FEEDBACK-1", "server")
    {:ok, view, _html} = live(conn, "/dcim/hardware-types/#{hardware_type.id}")

    view
    |> form("#new-revision-form",
      revision: %{
        width_mm: "0",
        specifications: "not json",
        templates: %{
          "0" => %{kind: "interface", name: "", attributes: "[]"}
        }
      }
    )
    |> render_change()

    assert has_element?(view, "#revision_width_mm.input-error")
    assert has_element?(view, "#revision_specifications.textarea-error")
    assert has_element?(view, "#component-template-fields [id$='-errors']", "Component 1")

    assert has_element?(
             view,
             "#component-template-fields input[name$='[name]'].input-error[aria-invalid='true'][aria-describedby$='_name-error']"
           )

    assert has_element?(
             view,
             "#component-template-fields textarea[name$='[attributes]'].textarea-error[aria-invalid='true'][aria-describedby$='_attributes-error']"
           )

    refute has_element?(view, "#flash-error")
  end

  test "oversized revision input is rejected without crashing or partial writes", %{
    conn: conn,
    scope: scope
  } do
    {:ok, manufacturer} = manufacturer_fixture(scope, "Oversized Vendor", "oversized-vendor")
    {:ok, hardware_type} = hardware_type_fixture(scope, manufacturer, "OVERSIZED-1", "server")
    {:ok, view, _html} = live(conn, "/dcim/hardware-types/#{hardware_type.id}")
    oversized = String.duplicate("p", 256)

    view
    |> form("#new-revision-form",
      revision: %{part_number: oversized, width_mm: "100000000.00", specifications: "{}"}
    )
    |> render_submit()

    assert has_element?(view, "#revision_part_number.input-error")
    assert has_element?(view, "#revision_width_mm.input-error")
    assert has_element?(view, "#new-revision-form input[value='#{oversized}']")
    assert Catalog.get_hardware_type!(scope, hardware_type.id).revisions == []
  end

  test "revision validation rejects precision loss and unrepresentable JSONB", %{
    conn: conn,
    scope: scope
  } do
    {:ok, manufacturer} = manufacturer_fixture(scope, "Precise Vendor", "precise-vendor")
    {:ok, hardware_type} = hardware_type_fixture(scope, manufacturer, "PRECISE-1", "server")
    {:ok, view, _html} = live(conn, "/dcim/hardware-types/#{hardware_type.id}")

    render_hook(view, "publish_revision", %{
      "revision" => %{
        "width_mm" => "1.005",
        "weight_kg" => "1.0005",
        "specifications" => ~s({"note":"\u0000"}),
        "templates" => %{
          "0" => %{
            "_persistent_id" => "jsonb-template",
            "kind" => "interface",
            "name" => "eth0",
            "attributes" => ~s({"note":"\u0000"})
          }
        }
      }
    })

    assert has_element?(view, "#revision_width_mm.input-error")
    assert has_element?(view, "#revision_weight_kg.input-error")
    assert has_element?(view, "#revision_specifications.textarea-error")
    assert has_element?(view, "#component-template-field-jsonb-template-errors")
    assert Catalog.get_hardware_type!(scope, hardware_type.id).revisions == []
  end

  test "revision authoring preserves and displays exact fractional JSON numbers", %{
    conn: conn,
    scope: scope
  } do
    {:ok, manufacturer} = manufacturer_fixture(scope, "Exact Vendor", "exact-vendor")
    {:ok, hardware_type} = hardware_type_fixture(scope, manufacturer, "EXACT-1", "server")
    {:ok, view, _html} = live(conn, "/dcim/hardware-types/#{hardware_type.id}")
    number = "0.123456789012345678901"

    render_hook(view, "publish_revision", %{
      "revision" => %{
        "specifications" => ~s({"ratio":#{number}}),
        "templates" => %{
          "0" => %{
            "_persistent_id" => "exact-template",
            "kind" => "interface",
            "name" => "eth0",
            "attributes" => ~s({"ratio":#{number}})
          }
        }
      }
    })

    assert {_path, _flash} = assert_redirect(view)
    [revision] = Catalog.get_hardware_type!(scope, hardware_type.id).revisions
    assert Decimal.equal?(revision.specifications["ratio"], Decimal.new(number))

    {:ok, detail, _html} = live(conn, "/dcim/hardware-types/#{hardware_type.id}")
    assert has_element?(detail, "#revision-1-specifications", number)

    assert has_element?(
             detail,
             "#component-template-#{List.first(revision.component_templates).id}-attributes",
             number
           )
  end

  test "revision events reject malformed parameter shapes without crashing", %{
    conn: conn,
    scope: scope
  } do
    {:ok, manufacturer} = manufacturer_fixture(scope, "Shape Vendor", "shape-vendor")
    {:ok, hardware_type} = hardware_type_fixture(scope, manufacturer, "SHAPE-1", "server")
    {:ok, view, _html} = live(conn, "/dcim/hardware-types/#{hardware_type.id}")

    render_hook(view, "validate_revision", %{"revision" => []})
    assert has_element?(view, "#new-revision-form")

    render_hook(view, "publish_revision", %{
      "revision" => %{"templates" => %{"0" => ["not", "an", "object"]}}
    })

    assert has_element?(view, "#component-template-fields", "must be an object")

    render_hook(view, "remove_component_template", %{})
    assert has_element?(view, "#flash-error", "could not be removed")
    assert Catalog.get_hardware_type!(scope, hardware_type.id).revisions == []
  end

  test "revision validation rejects case-only duplicate component identities", %{
    conn: conn,
    scope: scope
  } do
    {:ok, manufacturer} = manufacturer_fixture(scope, "Duplicate Vendor", "duplicate-vendor")
    {:ok, hardware_type} = hardware_type_fixture(scope, manufacturer, "DUPLICATE-1", "server")
    {:ok, view, _html} = live(conn, "/dcim/hardware-types/#{hardware_type.id}")

    render_change(view, "validate_revision", %{
      "revision" => %{
        "templates" => %{
          "0" => %{"_persistent_id" => "first", "kind" => "interface", "name" => "eth0"},
          "1" => %{"_persistent_id" => "duplicate", "kind" => "interface", "name" => "ETH0"}
        }
      }
    })

    assert has_element?(
             view,
             "#component-template-field-duplicate-errors",
             "Name has already been taken"
           )

    assert Catalog.get_hardware_type!(scope, hardware_type.id).revisions == []
  end

  test "tenant catalog lists exclude foreign records and foreign detail raises", %{
    conn: conn,
    scope: scope
  } do
    {:ok, local_manufacturer} = manufacturer_fixture(scope, "Local Vendor", "local-vendor")
    {:ok, local_type} = hardware_type_fixture(scope, local_manufacturer, "LOCAL-1", "server")

    {:ok, local_module_type} =
      module_type_fixture(scope, local_manufacturer, "LOCAL-MODULE", "line_card")

    foreign_user = user_fixture()
    foreign_organization = organization_fixture()
    organization_membership_fixture(foreign_user, foreign_organization, %{role: "admin"})
    foreign_scope = Renga.Accounts.scope_for_user(foreign_user, foreign_organization.id)

    {:ok, foreign_manufacturer} =
      manufacturer_fixture(foreign_scope, "Foreign Vendor", "foreign-vendor")

    {:ok, foreign_type} =
      hardware_type_fixture(foreign_scope, foreign_manufacturer, "SECRET-1", "server")

    {:ok, foreign_module_type} =
      module_type_fixture(foreign_scope, foreign_manufacturer, "SECRET-MODULE", "line_card")

    {:ok, manufacturers, _html} = live(conn, "/dcim/manufacturers")
    assert has_element?(manufacturers, "#manufacturer-#{local_manufacturer.id}")
    refute has_element?(manufacturers, "#manufacturer-#{foreign_manufacturer.id}")

    {:ok, types, _html} = live(conn, "/dcim/hardware-types")
    assert has_element?(types, "#hardware-type-#{local_type.id}")
    refute has_element?(types, "#hardware-type-#{foreign_type.id}")

    refute has_element?(
             types,
             "#new-hardware-type-form option[value='#{foreign_manufacturer.id}']"
           )

    {:ok, module_types, _html} = live(conn, "/dcim/module-types")
    assert has_element?(module_types, "#module-type-#{local_module_type.id}")
    refute has_element?(module_types, "#module-type-#{foreign_module_type.id}")

    assert_raise Ecto.NoResultsError, fn ->
      live(conn, "/dcim/hardware-types/#{foreign_type.id}")
    end

    assert_raise Ecto.NoResultsError, fn ->
      live(conn, "/dcim/module-types/#{foreign_module_type.id}")
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

    {:ok, manufacturer_view, _html} = live(viewer_conn, "/dcim/manufacturers")
    refute has_element?(manufacturer_view, "#new-manufacturer-form")

    render_hook(manufacturer_view, "create_manufacturer", %{
      "manufacturer" => %{
        "name" => "Forged Vendor",
        "slug" => "forged-vendor",
        "description" => ""
      }
    })

    assert has_element?(manufacturer_view, "#flash-error", "not allowed")
    assert Enum.map(Catalog.list_manufacturers(scope), & &1.id) == [manufacturer.id]

    render_hook(view, "publish_revision", %{
      "revision" => %{"part_number" => "FORGED-PN", "specifications" => "{}"}
    })

    assert has_element?(view, "#flash-error", "not allowed")
    assert Catalog.get_hardware_type!(scope, hardware_type.id).revisions == []
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

  defp module_type_fixture(scope, manufacturer, model, module_class) do
    Catalog.create_module_type(
      scope,
      %{name: "#{manufacturer.id}-module-#{model}", lifecycle_state: "active"},
      %{
        manufacturer_id: manufacturer.id,
        model: model,
        module_class: module_class,
        description: "#{model} module definition"
      }
    )
  end
end
