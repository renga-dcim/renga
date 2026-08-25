defmodule Renga.CatalogTest do
  use Renga.DataCase, async: true

  import Renga.AccountsFixtures
  import Renga.InventoryFixtures

  alias Renga.Accounts
  alias Renga.Catalog
  alias Renga.Catalog.ComponentTemplate
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
end
