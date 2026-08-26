defmodule Renga.CatalogTest do
  use Renga.DataCase, async: true

  import Renga.AccountsFixtures
  import Renga.InventoryFixtures

  alias Renga.Accounts
  alias Renga.Catalog
  alias Renga.Catalog.ComponentFinding
  alias Renga.Catalog.ComponentTemplate
  alias Renga.Catalog.ExpectedComponent
  alias Renga.Catalog.ExpectedComponentException
  alias Renga.Catalog.HardwareAssignment
  alias Renga.Catalog.HardwareType
  alias Renga.Catalog.Manufacturer
  alias Renga.Catalog.ModuleType
  alias Renga.Catalog.TypeRevision
  alias Renga.Inventory
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

    assert {:error, %Ecto.Changeset{errors: [model: {"has already been taken", _}]}} =
             module_type_fixture(scope, manufacturer, "rs-42", "line_card")
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
    scope: scope,
    organization: organization
  } do
    {:ok, manufacturer} = manufacturer_fixture(scope, "Managed", "managed")
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

    assert {:error, :forbidden} =
             Inventory.create_resource(member_scope, %{
               kind: "manufacturer",
               name: "Orphan envelope"
             })

    assert {:error, :forbidden} =
             Inventory.update_resource(member_scope, manufacturer.resource, %{
               name: "Bypassed catalog mutation"
             })

    assert {:error, changeset} =
             Inventory.update_resource(scope, manufacturer.resource, %{kind: "server"})

    assert %{kind: ["cannot be changed"]} = errors_on(changeset)
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

  test "database constraints reject every cross-tenant catalog relationship", %{scope: scope} do
    {:ok, manufacturer} = manufacturer_fixture(scope, "Private Vendor", "private-vendor")
    {:ok, hardware_type} = hardware_type_fixture(scope, manufacturer, "HW-1", "server")
    {:ok, module_type} = module_type_fixture(scope, manufacturer, "MOD-1", "line_card")

    {:ok, revision} =
      Catalog.create_hardware_type_revision(scope, hardware_type, %{}, [
        %{kind: "interface", name: "eth0"}
      ])

    other_user = user_fixture()
    other_organization = organization_fixture()
    organization_membership_fixture(other_user, other_organization, %{role: "admin"})
    other_scope = Accounts.scope_for_user(other_user, other_organization.id)
    {:ok, foreign_resource} = Inventory.create_resource(other_scope, %{kind: "server", name: "x"})

    assert {:error, manufacturer_changeset} =
             %Manufacturer{
               organization_id: scope.organization_id,
               resource_id: foreign_resource.id
             }
             |> Manufacturer.changeset(%{slug: "foreign-envelope"})
             |> Repo.insert()

    assert %{resource: [_]} = errors_on(manufacturer_changeset)

    assert {:error, %Ecto.Changeset{}} =
             %HardwareType{
               organization_id: scope.organization_id,
               resource_id: foreign_resource.id
             }
             |> HardwareType.changeset(%{
               manufacturer_id: manufacturer.id,
               model: "Foreign envelope hardware",
               device_class: "server"
             })
             |> Repo.insert()

    assert {:error, %Ecto.Changeset{}} =
             %ModuleType{
               organization_id: scope.organization_id,
               resource_id: foreign_resource.id
             }
             |> ModuleType.changeset(%{
               manufacturer_id: manufacturer.id,
               model: "Foreign envelope module",
               module_class: "line_card"
             })
             |> Repo.insert()

    assert {:error, %Ecto.Changeset{}} =
             module_type_fixture(other_scope, manufacturer, "Foreign module", "line_card")

    assert {:error, %Ecto.Changeset{}} =
             %TypeRevision{
               organization_id: other_scope.organization_id,
               hardware_type_id: hardware_type.id,
               revision: 1
             }
             |> TypeRevision.changeset(%{})
             |> Repo.insert()

    assert {:error, %Ecto.Changeset{}} =
             %TypeRevision{
               organization_id: other_scope.organization_id,
               module_type_id: module_type.id,
               revision: 1
             }
             |> TypeRevision.changeset(%{})
             |> Repo.insert()

    assert {:error, %Ecto.Changeset{}} =
             %ComponentTemplate{
               organization_id: other_scope.organization_id,
               catalog_type_revision_id: revision.id
             }
             |> ComponentTemplate.changeset(%{kind: "interface", name: "foreign"})
             |> Repo.insert()
  end

  test "published revisions and templates reject changesets", %{scope: scope} do
    {revision, template} = revision_fixture(scope)

    assert {:error, revision_changeset} =
             revision
             |> TypeRevision.changeset(%{part_number: "tampered"})
             |> Repo.update()

    assert %{base: ["catalog revision is immutable"]} = errors_on(revision_changeset)

    assert {:error, template_changeset} =
             template
             |> ComponentTemplate.changeset(%{name: "tampered"})
             |> Repo.update()

    assert %{base: ["component template is immutable"]} = errors_on(template_changeset)
  end

  test "database rejects revision updates that bypass changesets", %{scope: scope} do
    {revision, _template} = revision_fixture(scope)

    assert_raise Postgrex.Error, ~r/catalog revisions are immutable/, fn ->
      TypeRevision
      |> where([stored], stored.id == ^revision.id)
      |> Repo.update_all(set: [part_number: "tampered"])
    end
  end

  test "database rejects late templates on finalized revisions", %{scope: scope} do
    {revision, _template} = revision_fixture(scope)

    assert {:error, changeset} =
             %ComponentTemplate{
               organization_id: scope.organization_id,
               catalog_type_revision_id: revision.id
             }
             |> ComponentTemplate.changeset(%{kind: "interface", name: "late"})
             |> Repo.insert()

    assert %{catalog_type_revision: ["is finalized"]} = errors_on(changeset)
  end

  test "database rejects template updates that bypass changesets", %{scope: scope} do
    {_revision, template} = revision_fixture(scope)

    assert_raise Postgrex.Error, ~r/component templates are immutable/, fn ->
      ComponentTemplate
      |> where([stored], stored.id == ^template.id)
      |> Repo.update_all(set: [name: "tampered"])
    end
  end

  test "database rejects direct deletion of finalized revisions", %{scope: scope} do
    {revision, _template} = revision_fixture(scope)

    assert_raise Ecto.ConstraintError, ~r/catalog_type_revisions_immutable/, fn ->
      Repo.delete!(revision)
    end
  end

  test "database rejects direct deletion of finalized templates", %{scope: scope} do
    {_revision, template} = revision_fixture(scope)

    assert_raise Ecto.ConstraintError, ~r/component_templates_revision_finalized/, fn ->
      Repo.delete!(template)
    end
  end

  test "database rejects resource kind changes that bypass changesets", %{scope: scope} do
    {:ok, manufacturer} = manufacturer_fixture(scope, "Managed", "managed")

    assert_raise Postgrex.Error, ~r/resource kind is immutable/, fn ->
      Resource
      |> where([stored], stored.id == ^manufacturer.resource_id)
      |> Repo.update_all(set: [kind: "server"])
    end
  end

  test "operator assignments pin the latest revision until explicitly changed", %{scope: scope} do
    resource = physical_resource_fixture(scope, "operator-device")
    {:ok, manufacturer} = manufacturer_fixture(scope, "Acme", "acme")
    {:ok, hardware_type} = hardware_type_fixture(scope, manufacturer, "RS-42", "server")
    {:ok, first_revision} = Catalog.create_hardware_type_revision(scope, hardware_type, %{})

    assert {:ok, assignment} =
             Catalog.assign_hardware_type(scope, resource.id, hardware_type.id)

    assert assignment.origin == "operator"
    assert assignment.catalog_type_revision_id == first_revision.id
    assert assignment.provenance["user_id"] == scope.user.id

    {:ok, _second_revision} = Catalog.create_hardware_type_revision(scope, hardware_type, %{})

    assert Catalog.get_hardware_assignment(scope, resource.id).catalog_type_revision_id ==
             first_revision.id

    assert {:ok, nil} = Catalog.clear_hardware_assignment(scope, resource.id)
    refute Catalog.get_hardware_assignment(scope, resource.id)
  end

  test "clearing an assignment removes exception-backed expectations and resolves findings", %{
    scope: scope
  } do
    resource = physical_resource_fixture(scope, "cleared-exception-device")
    {:ok, manufacturer} = manufacturer_fixture(scope, "Acme", "acme")
    {:ok, hardware_type} = hardware_type_fixture(scope, manufacturer, "X1", "server")

    {:ok, revision} =
      Catalog.create_hardware_type_revision(scope, hardware_type, %{}, [
        %{kind: "cpu", name: "CPU1"},
        %{kind: "disk", name: "Disk1"}
      ])

    {:ok, assignment} = Catalog.assign_hardware_type(scope, resource.id, hardware_type.id)
    cpu_template = Enum.find(revision.component_templates, &(&1.name == "CPU1"))

    assert {:ok, _suppressed} =
             Catalog.put_expected_component_exception(scope, resource.id, %{
               action: "suppress",
               component_template_id: cpu_template.id
             })

    assert {:ok, _added} =
             Catalog.put_expected_component_exception(scope, resource.id, %{
               action: "add",
               kind: "memory",
               name: "DIMM1"
             })

    finding_ids = insert_assignment_findings(scope, resource, assignment)

    assert {:ok, nil} = Catalog.clear_hardware_assignment(scope, resource.id)
    refute Catalog.get_hardware_assignment(scope, resource.id)
    assert Catalog.list_expected_components(scope, resource.id) == []
    refute Repo.get_by(ExpectedComponentException, hardware_assignment_id: assignment.id)
    assert Catalog.list_component_findings(scope, resource.id, "open") == []

    assert Catalog.list_component_findings(scope, resource.id, "resolved")
           |> Enum.map(& &1.id)
           |> MapSet.new() == MapSet.new(finding_ids)
  end

  test "reconciliation normalizes manufacturer/model facts and preserves provenance", %{
    scope: scope
  } do
    resource = physical_resource_fixture(scope, "matched-device")

    {:ok, host} =
      Inventory.create_host(scope, resource.id, %{
        vendor: "  ACME, Inc. ",
        model: " rs 42 ",
        metadata: %{
          "field_owners" => %{
            "vendor" => %{"source_id" => "source-1"},
            "model" => %{"source_id" => "source-2"}
          }
        }
      })

    {:ok, manufacturer} = manufacturer_fixture(scope, "Acme Inc", "acme-inc")
    {:ok, hardware_type} = hardware_type_fixture(scope, manufacturer, "RS-42", "server")
    {:ok, revision} = Catalog.create_hardware_type_revision(scope, hardware_type, %{})

    assert {:ok, assignment} = Catalog.reconcile_hardware_type(scope, resource.id)
    assert assignment.origin == "reconciled"
    assert assignment.hardware_type_id == hardware_type.id
    assert assignment.catalog_type_revision_id == revision.id
    assert assignment.provenance["reported_vendor"] == host.vendor
    assert assignment.provenance["matched_by"] == "model"
    assert assignment.provenance["field_owners"]["model"]["source_id"] == "source-2"
  end

  test "reconciliation can match a reported product identifier to a revision part number", %{
    scope: scope
  } do
    resource = physical_resource_fixture(scope, "part-number-device")
    {:ok, _host} = Inventory.create_host(scope, resource.id, %{vendor: "Acme", model: "PN 123"})
    {:ok, manufacturer} = manufacturer_fixture(scope, "Acme", "acme")
    {:ok, hardware_type} = hardware_type_fixture(scope, manufacturer, "Friendly name", "server")

    {:ok, _revision} =
      Catalog.create_hardware_type_revision(scope, hardware_type, %{part_number: "PN-123"})

    assert {:ok, assignment} = Catalog.reconcile_hardware_type(scope, resource.id)
    assert assignment.hardware_type_id == hardware_type.id
    assert assignment.provenance["matched_by"] == "part_number"
  end

  test "part-number matching keeps the assigned revision pinned after newer revisions publish", %{
    scope: scope
  } do
    resource = physical_resource_fixture(scope, "pinned-part-number-device")
    {:ok, host} = Inventory.create_host(scope, resource.id, %{vendor: "Acme", model: "PN-1"})
    {:ok, manufacturer} = manufacturer_fixture(scope, "Acme", "acme")
    {:ok, hardware_type} = hardware_type_fixture(scope, manufacturer, "Friendly", "server")

    {:ok, first_revision} =
      Catalog.create_hardware_type_revision(scope, hardware_type, %{part_number: "PN-1"})

    assert {:ok, assignment} = Catalog.reconcile_hardware_type(scope, resource.id)
    assert assignment.catalog_type_revision_id == first_revision.id

    {:ok, _second_revision} =
      Catalog.create_hardware_type_revision(scope, hardware_type, %{part_number: "PN-2"})

    assert {:ok, pinned} = Catalog.reconcile_hardware_type(scope, resource.id)
    assert pinned.id == assignment.id
    assert pinned.catalog_type_revision_id == first_revision.id
    assert pinned.provenance["reported_model"] == "PN-1"

    host |> Renga.Inventory.Host.changeset(%{model: "PN-2"}) |> Repo.update!()

    assert {:ok, still_pinned} = Catalog.reconcile_hardware_type(scope, resource.id)
    assert still_pinned.id == assignment.id
    assert still_pinned.catalog_type_revision_id == first_revision.id
    assert still_pinned.provenance["reported_model"] == "PN-1"
  end

  test "ambiguous catalog matches remain findings and never select a candidate", %{scope: scope} do
    resource = physical_resource_fixture(scope, "ambiguous-device")
    {:ok, _host} = Inventory.create_host(scope, resource.id, %{vendor: "Shared", model: "X1"})

    for suffix <- ["one", "two"] do
      {:ok, manufacturer} =
        Catalog.create_manufacturer(
          scope,
          %{name: "Shared #{suffix}", lifecycle_state: "active"},
          %{slug: "shared-#{suffix}", metadata: %{"aliases" => ["Shared"]}}
        )

      {:ok, hardware_type} = hardware_type_fixture(scope, manufacturer, "X1", "server")
      {:ok, _revision} = Catalog.create_hardware_type_revision(scope, hardware_type, %{})
    end

    assert {:ok, nil} = Catalog.reconcile_hardware_type(scope, resource.id)
    refute Catalog.get_hardware_assignment(scope, resource.id)

    assert [finding] = Catalog.list_hardware_match_findings(scope)
    assert finding.kind == "ambiguous_catalog_match"
    assert length(finding.details["candidate_hardware_type_ids"]) == 2
  end

  test "operator assignment wins over later matching and matching keeps its pinned revision", %{
    scope: scope
  } do
    resource = physical_resource_fixture(scope, "authoritative-device")
    {:ok, _host} = Inventory.create_host(scope, resource.id, %{vendor: "Observed", model: "O1"})

    {:ok, observed_vendor} = manufacturer_fixture(scope, "Observed", "observed")
    {:ok, observed_type} = hardware_type_fixture(scope, observed_vendor, "O1", "server")
    {:ok, observed_revision} = Catalog.create_hardware_type_revision(scope, observed_type, %{})

    assert {:ok, reconciled} = Catalog.reconcile_hardware_type(scope, resource.id)
    assert reconciled.catalog_type_revision_id == observed_revision.id

    {:ok, _new_revision} = Catalog.create_hardware_type_revision(scope, observed_type, %{})
    assert {:ok, still_pinned} = Catalog.reconcile_hardware_type(scope, resource.id)
    assert still_pinned.catalog_type_revision_id == observed_revision.id

    {:ok, chosen_vendor} = manufacturer_fixture(scope, "Chosen", "chosen")
    {:ok, chosen_type} = hardware_type_fixture(scope, chosen_vendor, "C1", "server")
    {:ok, _chosen_revision} = Catalog.create_hardware_type_revision(scope, chosen_type, %{})
    assert {:ok, operator} = Catalog.assign_hardware_type(scope, resource.id, chosen_type.id)

    assert {:ok, unchanged} = Catalog.reconcile_hardware_type(scope, resource.id)
    assert unchanged.id == operator.id
    assert unchanged.hardware_type_id == chosen_type.id
  end

  test "assignment mutations enforce resource, tenant, revision, and authorization boundaries", %{
    scope: scope,
    organization: organization
  } do
    resource = physical_resource_fixture(scope, "bounded-device")
    {:ok, manufacturer} = manufacturer_fixture(scope, "Acme", "acme")
    {:ok, hardware_type} = hardware_type_fixture(scope, manufacturer, "X1", "server")
    {:ok, revision} = Catalog.create_hardware_type_revision(scope, hardware_type, %{})
    nonphysical = Catalog.get_manufacturer!(scope, manufacturer.id).resource

    assert {:error, :unsupported_resource_kind} =
             Catalog.assign_hardware_type(scope, nonphysical.id, hardware_type.id)

    member = user_fixture()
    organization_membership_fixture(member, organization, %{role: "member"})
    member_scope = Accounts.scope_for_user(member, organization.id)

    assert {:error, :forbidden} =
             Catalog.assign_hardware_type(member_scope, resource.id, hardware_type.id)

    other_user = user_fixture()
    other_organization = organization_fixture()
    organization_membership_fixture(other_user, other_organization, %{role: "admin"})
    other_scope = Accounts.scope_for_user(other_user, other_organization.id)
    foreign_resource = physical_resource_fixture(other_scope, "foreign-device")

    assert {:error, changeset} =
             %HardwareAssignment{
               organization_id: other_scope.organization_id,
               resource_id: foreign_resource.id
             }
             |> HardwareAssignment.changeset(%{
               hardware_type_id: hardware_type.id,
               catalog_type_revision_id: revision.id,
               origin: "operator"
             })
             |> Repo.insert()

    assert errors_on(changeset) != %{}

    assert {:ok, assignment} = Catalog.assign_hardware_type(scope, resource.id, hardware_type.id)
    {:ok, newer_revision} = Catalog.create_hardware_type_revision(scope, hardware_type, %{})

    assert {:error, mismatched_revision_changeset} =
             %ExpectedComponent{
               organization_id: scope.organization_id,
               hardware_assignment_id: assignment.id
             }
             |> ExpectedComponent.changeset(%{
               catalog_type_revision_id: newer_revision.id,
               kind: "interface",
               name: "cross-revision",
               required: true,
               suppressed: false
             })
             |> Repo.insert()

    assert %{hardware_assignment: [_]} = errors_on(mismatched_revision_changeset)
  end

  test "assignment materializes expectations from its pinned revision", %{scope: scope} do
    resource = physical_resource_fixture(scope, "expected-device")
    {:ok, manufacturer} = manufacturer_fixture(scope, "Acme", "acme")
    {:ok, hardware_type} = hardware_type_fixture(scope, manufacturer, "X1", "server")

    {:ok, revision} =
      Catalog.create_hardware_type_revision(scope, hardware_type, %{}, [
        %{kind: "interface", name: "eth0", label: "Management", attributes: %{"speed" => 1_000}},
        %{kind: "module_bay", name: "PSU1", position: "rear-left"},
        %{kind: "cpu", name: "CPU1", position: "socket-1", attributes: %{"model" => "CPU-X"}},
        %{kind: "memory", name: "DIMM1", position: "A1", attributes: %{"size_bytes" => 16_384}},
        %{kind: "disk", name: "Disk1", position: "bay-1", attributes: %{"part_number" => "D-1"}}
      ])

    assert {:ok, _assignment} = Catalog.assign_hardware_type(scope, resource.id, hardware_type.id)
    components = Catalog.list_expected_components(scope, resource.id)
    psu = Enum.find(components, &(&1.name == "PSU1"))
    eth0 = Enum.find(components, &(&1.name == "eth0"))
    cpu = Enum.find(components, &(&1.name == "CPU1"))
    memory = Enum.find(components, &(&1.name == "DIMM1"))
    disk = Enum.find(components, &(&1.name == "Disk1"))

    assert psu.catalog_type_revision_id == revision.id
    assert psu.component_template_id
    assert psu.position == "rear-left"
    assert eth0.label == "Management"
    assert eth0.attributes == %{"speed" => 1_000}
    assert cpu.position == "socket-1"
    assert cpu.attributes == %{"model" => "CPU-X"}
    assert memory.kind == "memory"
    assert disk.attributes == %{"part_number" => "D-1"}

    {:ok, replacement_type} = hardware_type_fixture(scope, manufacturer, "X2", "server")

    {:ok, replacement_revision} =
      Catalog.create_hardware_type_revision(scope, replacement_type, %{}, [
        %{kind: "interface", name: "replacement0"}
      ])

    assert {:ok, _replacement_assignment} =
             Catalog.assign_hardware_type(scope, resource.id, replacement_type.id)

    assert [replacement] = Catalog.list_expected_components(scope, resource.id)
    assert replacement.name == "replacement0"
    assert replacement.catalog_type_revision_id == replacement_revision.id
  end

  test "confirmed add, suppress, and alter exceptions rematerialize local expectations", %{
    scope: scope
  } do
    resource = physical_resource_fixture(scope, "exception-device")
    {:ok, manufacturer} = manufacturer_fixture(scope, "Acme", "acme")
    {:ok, hardware_type} = hardware_type_fixture(scope, manufacturer, "X1", "server")

    {:ok, revision} =
      Catalog.create_hardware_type_revision(scope, hardware_type, %{}, [
        %{kind: "interface", name: "eth0", label: "Original", attributes: %{"speed" => 1_000}},
        %{kind: "power_port", name: "PSU1"}
      ])

    eth0_template = Enum.find(revision.component_templates, &(&1.name == "eth0"))
    psu_template = Enum.find(revision.component_templates, &(&1.name == "PSU1"))
    {:ok, _assignment} = Catalog.assign_hardware_type(scope, resource.id, hardware_type.id)

    assert {:ok, altered} =
             Catalog.put_expected_component_exception(scope, resource.id, %{
               action: "alter",
               component_template_id: eth0_template.id,
               changes: %{"label" => "Dedicated", "attributes" => %{"mtu" => 9_000}}
             })

    assert {:ok, _suppressed} =
             Catalog.put_expected_component_exception(scope, resource.id, %{
               action: "suppress",
               component_template_id: psu_template.id
             })

    assert {:ok, added} =
             Catalog.put_expected_component_exception(scope, resource.id, %{
               action: "add",
               kind: "interface",
               name: "eth1",
               changes: %{"label" => "Local", "attributes" => %{"speed" => 10_000}}
             })

    assert {:ok, _added_disk} =
             Catalog.put_expected_component_exception(scope, resource.id, %{
               action: "add",
               kind: "disk",
               name: "local-disk",
               changes: %{"position" => "bay-2", "attributes" => %{"part_number" => "D-2"}}
             })

    components = Catalog.list_expected_components(scope, resource.id)
    eth0 = Enum.find(components, &(&1.name == "eth0"))
    eth1 = Enum.find(components, &(&1.name == "eth1"))
    local_disk = Enum.find(components, &(&1.name == "local-disk"))
    psu = Enum.find(components, &(&1.name == "PSU1"))

    assert eth0.label == "Dedicated"
    assert eth0.attributes == %{"speed" => 1_000, "mtu" => 9_000}
    assert eth0.exception_id == altered.id
    assert eth1.component_template_id == nil
    assert eth1.exception_id == added.id
    assert eth1.label == "Local"
    assert local_disk.kind == "disk"
    assert local_disk.position == "bay-2"
    assert psu.suppressed

    assert {:ok, nil} =
             Catalog.delete_expected_component_exception(scope, resource.id, altered.id)

    reset_eth0 =
      Enum.find(Catalog.list_expected_components(scope, resource.id), &(&1.name == "eth0"))

    assert reset_eth0.label == "Original"
    assert reset_eth0.attributes == %{"speed" => 1_000}
  end

  test "reassignment replaces assignment identity and removes its old exceptions", %{scope: scope} do
    resource = physical_resource_fixture(scope, "reassigned-exception-device")
    {:ok, manufacturer} = manufacturer_fixture(scope, "Acme", "acme")
    {:ok, first_type} = hardware_type_fixture(scope, manufacturer, "X1", "server")
    {:ok, second_type} = hardware_type_fixture(scope, manufacturer, "X2", "server")

    {:ok, first_revision} =
      Catalog.create_hardware_type_revision(scope, first_type, %{}, [
        %{kind: "interface", name: "old0"}
      ])

    {:ok, _second_revision} =
      Catalog.create_hardware_type_revision(scope, second_type, %{}, [
        %{kind: "interface", name: "new0"}
      ])

    {:ok, first_assignment} = Catalog.assign_hardware_type(scope, resource.id, first_type.id)
    old_template = List.first(first_revision.component_templates)

    {:ok, _exception} =
      Catalog.put_expected_component_exception(scope, resource.id, %{
        action: "suppress",
        component_template_id: old_template.id
      })

    finding_ids = insert_assignment_findings(scope, resource, first_assignment)

    assert {:ok, second_assignment} =
             Catalog.assign_hardware_type(scope, resource.id, second_type.id)

    refute second_assignment.id == first_assignment.id
    refute Repo.get(HardwareAssignment, first_assignment.id)
    refute Repo.get_by(ExpectedComponentException, hardware_assignment_id: first_assignment.id)
    assert Enum.map(Catalog.list_expected_components(scope, resource.id), & &1.name) == ["new0"]
    assert Catalog.list_component_findings(scope, resource.id, "open") == []

    assert Catalog.list_component_findings(scope, resource.id, "resolved")
           |> Enum.map(& &1.id)
           |> MapSet.new() == MapSet.new(finding_ids)
  end

  test "exception updates support local additions and record the current confirmer", %{
    scope: scope,
    organization: organization
  } do
    resource = physical_resource_fixture(scope, "updated-exception-device")
    {:ok, manufacturer} = manufacturer_fixture(scope, "Acme", "acme")
    {:ok, hardware_type} = hardware_type_fixture(scope, manufacturer, "X1", "server")

    {:ok, revision} =
      Catalog.create_hardware_type_revision(scope, hardware_type, %{}, [
        %{kind: "power_port", name: "PSU1"}
      ])

    {:ok, _assignment} = Catalog.assign_hardware_type(scope, resource.id, hardware_type.id)

    {:ok, added} =
      Catalog.put_expected_component_exception(scope, resource.id, %{
        action: "add",
        kind: "interface",
        name: "eth1"
      })

    second_manager = user_fixture()
    organization_membership_fixture(second_manager, organization, %{role: "admin"})
    second_scope = Accounts.scope_for_user(second_manager, organization.id)

    assert {:ok, updated} =
             Catalog.put_expected_component_exception(second_scope, resource.id, %{
               exception_id: added.id,
               action: "add",
               kind: "interface",
               name: "eth2",
               changes: %{"label" => "Updated"}
             })

    assert updated.id == added.id
    assert updated.confirmed_by_user_id == second_manager.id

    assert [%{name: "eth2", label: "Updated"}] =
             Catalog.list_expected_components(scope, resource.id)
             |> Enum.filter(&(&1.kind == "interface"))

    template = List.first(revision.component_templates)

    assert {:ok, suppressed} =
             Catalog.put_expected_component_exception(scope, resource.id, %{
               action: "suppress",
               component_template_id: template.id
             })

    assert {:ok, altered} =
             Catalog.put_expected_component_exception(second_scope, resource.id, %{
               action: "alter",
               component_template_id: template.id,
               changes: %{"label" => "Replacement manager"}
             })

    assert altered.id == suppressed.id
    assert altered.confirmed_by_user_id == second_manager.id
  end

  test "exceptions require management access and templates from the pinned revision", %{
    scope: scope,
    organization: organization
  } do
    resource = physical_resource_fixture(scope, "protected-exception-device")
    {:ok, manufacturer} = manufacturer_fixture(scope, "Acme", "acme")
    {:ok, first_type} = hardware_type_fixture(scope, manufacturer, "X1", "server")
    {:ok, second_type} = hardware_type_fixture(scope, manufacturer, "X2", "server")

    {:ok, _first_revision} =
      Catalog.create_hardware_type_revision(scope, first_type, %{}, [
        %{kind: "interface", name: "eth0"}
      ])

    {:ok, second_revision} =
      Catalog.create_hardware_type_revision(scope, second_type, %{}, [
        %{kind: "interface", name: "foreign-template"}
      ])

    {:ok, _assignment} = Catalog.assign_hardware_type(scope, resource.id, first_type.id)
    foreign_template = List.first(second_revision.component_templates)

    assert {:error, :invalid_component_template} =
             Catalog.put_expected_component_exception(scope, resource.id, %{
               action: "suppress",
               component_template_id: foreign_template.id
             })

    member = user_fixture()
    organization_membership_fixture(member, organization, %{role: "member"})
    member_scope = Accounts.scope_for_user(member, organization.id)

    assert {:error, :forbidden} =
             Catalog.put_expected_component_exception(member_scope, resource.id, %{
               action: "add",
               kind: "interface",
               name: "unauthorized"
             })
  end

  test "database rejects exceptions whose template is from another revision", %{scope: scope} do
    resource = physical_resource_fixture(scope, "cross-revision-exception-device")
    {:ok, manufacturer} = manufacturer_fixture(scope, "Acme", "acme")
    {:ok, first_type} = hardware_type_fixture(scope, manufacturer, "X1", "server")
    {:ok, second_type} = hardware_type_fixture(scope, manufacturer, "X2", "server")
    {:ok, _first_revision} = Catalog.create_hardware_type_revision(scope, first_type, %{})

    {:ok, second_revision} =
      Catalog.create_hardware_type_revision(scope, second_type, %{}, [
        %{kind: "interface", name: "foreign0"}
      ])

    {:ok, assignment} = Catalog.assign_hardware_type(scope, resource.id, first_type.id)
    foreign_template = List.first(second_revision.component_templates)

    assert {:error, changeset} =
             %ExpectedComponentException{
               organization_id: scope.organization_id,
               hardware_assignment_id: assignment.id,
               catalog_type_revision_id: assignment.catalog_type_revision_id,
               confirmed_by_user_id: scope.user.id
             }
             |> ExpectedComponentException.changeset(%{
               action: "suppress",
               component_template_id: foreign_template.id
             })
             |> Repo.insert()

    assert %{component_template: [_]} = errors_on(changeset)
  end

  test "manufacturer aliases reject malformed values without breaking unrelated matching", %{
    scope: scope
  } do
    assert {:error, changeset} =
             Catalog.create_manufacturer(
               scope,
               %{name: "Malformed", lifecycle_state: "active"},
               %{slug: "malformed", metadata: %{"aliases" => "not-a-list"}}
             )

    assert %{metadata: [_]} = errors_on(changeset)

    for {suffix, aliases} <- [{"blank", [""]}, {"non-string", ["valid", 42]}] do
      assert {:error, invalid_alias_changeset} =
               Catalog.create_manufacturer(
                 scope,
                 %{name: "Malformed #{suffix}", lifecycle_state: "active"},
                 %{slug: "malformed-#{suffix}", metadata: %{"aliases" => aliases}}
               )

      assert %{metadata: [_]} = errors_on(invalid_alias_changeset)
    end

    {:ok, malformed} = manufacturer_fixture(scope, "Malformed stored", "malformed-stored")

    Manufacturer
    |> where([manufacturer], manufacturer.id == ^malformed.id)
    |> Repo.update_all(set: [metadata: %{"aliases" => %{"bad" => "shape"}}])

    resource = physical_resource_fixture(scope, "unrelated-alias-device")
    {:ok, _host} = Inventory.create_host(scope, resource.id, %{vendor: "Valid", model: "X1"})
    {:ok, valid} = manufacturer_fixture(scope, "Valid", "valid")
    {:ok, hardware_type} = hardware_type_fixture(scope, valid, "X1", "server")
    {:ok, _revision} = Catalog.create_hardware_type_revision(scope, hardware_type, %{})

    assert {:ok, assignment} = Catalog.reconcile_hardware_type(scope, resource.id)
    assert assignment.hardware_type_id == hardware_type.id
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

  defp revision_fixture(scope) do
    {:ok, manufacturer} =
      manufacturer_fixture(
        scope,
        "Vendor #{System.unique_integer()}",
        "vendor-#{System.unique_integer([:positive])}"
      )

    {:ok, hardware_type} =
      hardware_type_fixture(scope, manufacturer, "HW-#{System.unique_integer()}", "server")

    {:ok, revision} =
      Catalog.create_hardware_type_revision(scope, hardware_type, %{part_number: "original"}, [
        %{kind: "interface", name: "eth0"}
      ])

    {revision, List.first(revision.component_templates)}
  end

  defp physical_resource_fixture(scope, name) do
    {:ok, resource} =
      Inventory.create_resource(scope, %{kind: "server", name: name, lifecycle_state: "active"})

    resource
  end

  defp insert_assignment_findings(scope, resource, assignment) do
    observed_at = ~U[2026-08-26 12:00:00.000000Z]

    ~w(ambiguous_expected_component component_drift missing_expected_component unexpected_actual_component)
    |> Enum.map(fn kind ->
      %ComponentFinding{
        organization_id: scope.organization_id,
        resource_id: resource.id
      }
      |> ComponentFinding.changeset(%{
        kind: kind,
        resolution_key: "assignment:#{assignment.id}:#{kind}",
        message: "Assignment-dependent test finding",
        details: %{"hardware_assignment_id" => assignment.id},
        last_observed_at: observed_at
      })
      |> Repo.insert!()
      |> Map.fetch!(:id)
    end)
  end
end
