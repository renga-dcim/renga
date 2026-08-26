defmodule Renga.Inventory.ReconcilerTest do
  use Renga.DataCase, async: true

  alias Renga.Accounts
  alias Renga.Catalog
  alias Renga.Catalog.ActualComponentEvidenceMatch
  alias Renga.Catalog.ComponentFinding
  alias Renga.Inventory
  alias Renga.Inventory.AddressEvidence
  alias Renga.Inventory.ComponentEvidence
  alias Renga.Inventory.InterfaceEvidence
  alias Renga.Inventory.ResourceIdentifierClaim

  defp context do
    suffix = System.unique_integer([:positive])

    {:ok, organization} =
      Accounts.create_organization(%{
        name: "Reconciliation #{suffix}",
        slug: "reconciliation-#{suffix}"
      })

    {:ok, user} =
      Accounts.register_user(%{email: "reconciler-actor-#{suffix}@example.com"})

    {:ok, _membership} =
      Accounts.create_organization_membership(organization, %{
        user_id: user.id,
        role: "admin",
        status: "active"
      })

    scope = Accounts.scope_for_user(user, organization.id)

    {:ok, source} =
      Inventory.create_source(scope, %{kind: "host_agent", name: "host-agent-#{suffix}"})

    %{scope: scope, source: source}
  end

  defp observation(
         context,
         id,
         identifiers,
         attributes \\ %{},
         interfaces \\ [],
         components \\ :absent
       ) do
    observed_at = DateTime.add(~U[2026-08-01 12:00:00.000Z], String.to_integer(id), :second)

    observation_at(context, id, observed_at, identifiers, attributes, interfaces, components)
  end

  defp observation_at(
         context,
         id,
         observed_at,
         identifiers,
         attributes,
         interfaces,
         components \\ :absent
       ) do
    resource_payload =
      %{
        "kind" => "server",
        "identifiers" => identifiers,
        "attributes" => attributes
      }
      |> then(fn payload ->
        if interfaces == :absent, do: payload, else: Map.put(payload, "interfaces", interfaces)
      end)
      |> then(fn payload ->
        if components == :absent, do: payload, else: Map.put(payload, "components", components)
      end)

    {:ok, observation} =
      Inventory.create_observation(context.scope, context.source.id, %{
        idempotency_key: "observation-#{id}",
        observed_at: observed_at,
        payload: %{
          "observation_id" => "observation-#{id}",
          "observed_at" => DateTime.to_iso8601(observed_at),
          "resources" => [resource_payload]
        }
      })

    observation
  end

  test "discovers a host and preserves canonical identifiers and source claims" do
    context = context()

    observation =
      observation(
        context,
        "1",
        %{"hostname" => "Compute-01", "machine_id" => "AABBCCDD"},
        %{"hostname" => "Compute-01", "vendor" => "Dell", "model" => "R760"}
      )

    assert {:ok, resource, true} = Inventory.reconcile_observation(context.scope, observation.id)
    assert resource.name == "compute-01"
    assert resource.lifecycle_state == "unknown"

    assert host = Inventory.get_host_by_resource!(context.scope, resource.id)
    assert host.hostname == "compute-01"
    assert host.vendor == "Dell"

    identifiers = Inventory.list_resource_identifiers(context.scope, resource.id)

    assert Enum.map(identifiers, &{&1.kind, &1.normalized_value}) == [
             {"hostname", "compute-01"},
             {"machine_id", "aabbccdd"}
           ]

    claims = Inventory.list_resource_identifier_claims(context.scope, resource.id)
    assert Enum.map(claims, &{&1.kind, &1.confidence}) == [{"hostname", 60}, {"machine_id", 100}]

    assert [%{status: "succeeded", matched_resource_id: resource_id}] =
             Inventory.list_observation_reconciliations(context.scope, observation.id)

    assert resource_id == resource.id
    assert [%{kind: "discovered"}] = Inventory.list_change_events(context.scope, resource.id)

    assert [%{type: "InventoryCurrent", status: "true"}] =
             Inventory.list_resource_conditions(context.scope, resource.id)
  end

  test "promotes supported shape-open components into typed immutable evidence" do
    context = context()

    components = [
      %{"kind" => "os", "name" => "Example OS"},
      %{"kind" => "cpu", "model" => "Example CPU", "logical_count" => 8},
      %{"kind" => "memory", "total_bytes" => 16_384},
      %{
        "kind" => "disk",
        "name" => "disk0",
        "serial_number" => "SERIAL-1",
        "part_number" => "PART-1",
        "slot" => "bay-1",
        "size_bytes" => 1_000_000,
        "metadata" => %{"collector" => "portable"}
      },
      %{
        "kind" => "module",
        "id" => "line-card-1",
        "slot" => "SLOT1",
        "model" => "LC-48",
        "part_number" => "PN-LC",
        "manufacturer" => "Example Networks",
        "metadata" => %{"collector" => "bmc"}
      },
      %{"kind" => "module", "id" => "unpositioned-module"},
      %{"kind" => "disk", "name" => %{"malformed" => true}}
    ]

    observation =
      observation(
        context,
        "1",
        %{"machine_id" => "machine-1"},
        %{},
        [],
        components
      )

    assert {:ok, resource, true} =
             Inventory.reconcile_observation(context.scope, observation.id)

    assert [cpu, disk, memory, module] =
             Inventory.list_component_evidence(context.scope, resource.id)

    assert %{kind: "cpu", source_local_id: "cpu", model: "Example CPU"} = cpu
    assert cpu.attributes == %{"logical_count" => 8}

    assert %{
             kind: "disk",
             source_local_id: "SERIAL-1",
             name: "disk0",
             slot: "bay-1",
             serial_number: "SERIAL-1",
             part_number: "PART-1"
           } = disk

    assert disk.attributes == %{"size_bytes" => 1_000_000}
    assert disk.raw_metadata == %{"collector" => "portable"}
    assert %{kind: "memory", source_local_id: "memory"} = memory
    assert memory.attributes == %{"total_bytes" => 16_384}

    assert %{
             kind: "module",
             source_local_id: "line-card-1",
             slot: "SLOT1",
             model: "LC-48",
             part_number: "PN-LC"
           } = module

    assert module.attributes == %{"manufacturer" => "Example Networks"}
    assert module.raw_metadata == %{"collector" => "bmc"}
    assert Catalog.list_actual_components(context.scope, resource.id) |> length() == 3
    assert Catalog.list_component_findings(context.scope, resource.id) == []

    assert Enum.at(observation.payload["resources"], 0)["components"] == components

    assert {:ok, ^resource, false} =
             Inventory.reconcile_observation(context.scope, observation.id)

    assert Repo.aggregate(ComponentEvidence, :count) == 4
  end

  test "module evidence requires stable identity and a normalized bay address" do
    context = context()
    first = observation(context, "1", %{"machine_id" => "machine-1"})
    assert {:ok, resource, true} = Inventory.reconcile_observation(context.scope, first.id)

    hardware_type =
      hardware_type_fixture(context.scope, "MODULE-EVIDENCE", [
        %{kind: "module_bay", name: "Slot 1", position: "SLOT1"}
      ])

    assert {:ok, _assignment} =
             Catalog.assign_hardware_type(context.scope, resource.id, hardware_type.id)

    components = [
      %{"kind" => "module", "id" => "card-id", "slot" => "SLOT1"},
      %{
        "kind" => "module",
        "source_local_id" => "card-path",
        "slot" => "  ",
        "path" => "/chassis/slot-2"
      },
      %{
        "kind" => "module",
        "serial_number" => "SERIAL-3",
        "slot" => %{"malformed" => true},
        "path" => "/chassis/slot-3"
      },
      %{"kind" => "module", "slot" => "SLOT4"},
      %{"kind" => "module", "name" => "Named only", "path" => "/chassis/slot-5"}
    ]

    reported =
      observation(
        context,
        "2",
        %{"machine_id" => "machine-1"},
        %{},
        [],
        components
      )

    assert {:ok, ^resource, false} = Inventory.reconcile_observation(context.scope, reported.id)

    evidence_by_identity =
      context.scope
      |> Inventory.list_component_evidence(resource.id)
      |> Map.new(&{&1.source_local_id, &1})

    assert Map.keys(evidence_by_identity) |> Enum.sort() == ~w(SERIAL-3 card-id card-path)
    assert evidence_by_identity["card-id"].slot == "SLOT1"
    assert evidence_by_identity["card-path"].slot == nil
    assert evidence_by_identity["card-path"].path == "/chassis/slot-2"
    assert evidence_by_identity["SERIAL-3"].path == "/chassis/slot-3"

    for evidence <- Map.values(evidence_by_identity) do
      assert evidence.organization_id == context.scope.organization_id
      assert evidence.resource_id == resource.id
      assert evidence.source_id == context.source.id
      assert evidence.observation_id == reported.id
      assert evidence.observed_at == reported.observed_at
    end

    assert Enum.at(reported.payload["resources"], 0)["components"] == components
    assert Catalog.list_actual_components(context.scope, resource.id) == []
    assert Catalog.list_component_findings(context.scope, resource.id) == []
  end

  test "duplicate module identities remain only in the immutable observation" do
    context = context()
    first = observation(context, "1", %{"machine_id" => "machine-1"})
    assert {:ok, resource, true} = Inventory.reconcile_observation(context.scope, first.id)

    components = [
      %{"kind" => "module", "id" => "duplicate-card", "slot" => "SLOT1"},
      %{"kind" => "module", "id" => "duplicate-card", "slot" => "SLOT2"}
    ]

    conflicting =
      observation(
        context,
        "2",
        %{"machine_id" => "machine-1"},
        %{},
        [],
        components
      )

    assert {:ok, ^resource, false} =
             Inventory.reconcile_observation(context.scope, conflicting.id)

    assert Inventory.list_component_evidence(context.scope, resource.id) == []
    assert Enum.at(conflicting.payload["resources"], 0)["components"] == components
  end

  test "module evidence persistence requires a bay address" do
    context = context()
    observation = observation(context, "1", %{"machine_id" => "machine-1"})
    assert {:ok, resource, true} = Inventory.reconcile_observation(context.scope, observation.id)

    assert {:error, changeset} =
             Inventory.create_component_evidence(
               context.scope,
               context.source.id,
               observation.id,
               resource.id,
               %{kind: "module", source_local_id: "card-1"}
             )

    assert "slot or path is required for module evidence" in errors_on(changeset).slot

    assert_raise Ecto.ConstraintError, ~r/component_evidence_module_position/, fn ->
      Repo.insert!(%ComponentEvidence{
        organization_id: context.scope.organization_id,
        resource_id: resource.id,
        source_id: context.source.id,
        observation_id: observation.id,
        kind: "module",
        source_local_id: "card-2",
        observed_at: observation.observed_at
      })
    end
  end

  test "nullable components remain raw without blocking reconciliation" do
    context = context()

    observation =
      observation(
        context,
        "1",
        %{"machine_id" => "machine-1"},
        %{},
        [],
        nil
      )

    assert {:ok, resource, true} =
             Inventory.reconcile_observation(context.scope, observation.id)

    assert Inventory.list_component_evidence(context.scope, resource.id) == []
    assert Enum.at(observation.payload["resources"], 0)["components"] == nil
  end

  test "positional CPU and memory components retain distinct source identities" do
    context = context()

    observation =
      observation(
        context,
        "1",
        %{"machine_id" => "machine-1"},
        %{},
        [],
        [
          %{"kind" => "cpu", "slot" => "CPU1", "model" => "Example CPU"},
          %{"kind" => "cpu", "slot" => "CPU2", "model" => "Example CPU"},
          %{"kind" => "memory", "slot" => "DIMM1", "total_bytes" => 8_192},
          %{"kind" => "memory", "slot" => "DIMM2", "total_bytes" => 8_192}
        ]
      )

    assert {:ok, resource, true} =
             Inventory.reconcile_observation(context.scope, observation.id)

    assert context.scope
           |> Inventory.list_component_evidence(resource.id)
           |> Enum.map(&{&1.kind, &1.source_local_id, &1.slot}) == [
             {"cpu", "CPU1", "CPU1"},
             {"cpu", "CPU2", "CPU2"},
             {"memory", "DIMM1", "DIMM1"},
             {"memory", "DIMM2", "DIMM2"}
           ]

    assert {:ok, ^resource, false} =
             Inventory.reconcile_observation(context.scope, observation.id)

    assert Repo.aggregate(ComponentEvidence, :count) == 4
  end

  test "canonical components match by serial, provider identity, then position and part number" do
    context = context()

    first =
      observation(
        context,
        "1",
        %{"machine_id" => "machine-1"},
        %{},
        [],
        [
          %{
            "kind" => "cpu",
            "id" => "provider-cpu",
            "slot" => "CPU1",
            "model" => "Original CPU",
            "physical_count" => 1
          },
          %{
            "kind" => "disk",
            "id" => "provider-disk",
            "serial_number" => "SERIAL-1",
            "slot" => "BAY1",
            "part_number" => "DISK-PN"
          },
          %{
            "kind" => "memory",
            "id" => "provider-memory",
            "slot" => "DIMM1",
            "part_number" => "MEM-PN"
          }
        ]
      )

    assert {:ok, resource, true} = Inventory.reconcile_observation(context.scope, first.id)

    provider_update =
      observation(
        context,
        "2",
        %{"machine_id" => "machine-1"},
        %{},
        [],
        [
          %{
            "kind" => "cpu",
            "id" => "provider-cpu",
            "slot" => "CPU1",
            "model" => "Updated CPU",
            "logical_count" => 16
          }
        ]
      )

    assert {:ok, ^resource, false} =
             Inventory.reconcile_observation(context.scope, provider_update.id)

    {:ok, second_source} =
      Inventory.create_source(context.scope, %{kind: "bmc", name: "component-bmc"})

    second_context = %{context | source: second_source}

    serial_and_position =
      observation(
        second_context,
        "3",
        %{"machine_id" => "machine-1"},
        %{},
        [],
        [
          %{
            "kind" => "disk",
            "id" => "bmc-disk",
            "serial_number" => "serial-1",
            "slot" => "BAY9",
            "part_number" => "OTHER-PN"
          },
          %{
            "kind" => "memory",
            "id" => "bmc-memory",
            "slot" => "dimm1",
            "part_number" => "mem-pn",
            "model" => "Observed DIMM"
          }
        ]
      )

    assert {:ok, ^resource, false} =
             Inventory.reconcile_observation(context.scope, serial_and_position.id)

    assert [cpu, disk, memory] = Catalog.list_actual_components(context.scope, resource.id)

    assert cpu.model == "Updated CPU"
    assert cpu.attributes == %{"logical_count" => 16, "physical_count" => 1}

    assert Enum.map(cpu.evidence_matches, & &1.match_strategy) |> Enum.sort() ==
             ~w(discovered provider_id)

    assert disk.serial_number == "serial-1"
    assert disk.slot == "BAY9"

    assert Enum.map(disk.evidence_matches, & &1.match_strategy) |> Enum.sort() ==
             ~w(discovered serial_number)

    assert memory.model == "Observed DIMM"

    assert Enum.map(memory.evidence_matches, & &1.match_strategy) |> Enum.sort() ==
             ~w(discovered position_part_number)
  end

  test "older evidence links without regressing the canonical component projection" do
    context = context()

    newer =
      observation(
        context,
        "2",
        %{"machine_id" => "machine-1"},
        %{},
        [],
        [%{"kind" => "cpu", "id" => "cpu-1", "model" => "New model"}]
      )

    older =
      observation(
        context,
        "1",
        %{"machine_id" => "machine-1"},
        %{},
        [],
        [%{"kind" => "cpu", "id" => "cpu-1", "model" => "Old model"}]
      )

    assert {:ok, resource, true} = Inventory.reconcile_observation(context.scope, newer.id)
    assert {:ok, ^resource, false} = Inventory.reconcile_observation(context.scope, older.id)

    assert [component] = Catalog.list_actual_components(context.scope, resource.id)
    assert component.model == "New model"
    assert component.first_observed_at == older.observed_at
    assert component.last_observed_at == newer.observed_at
    assert length(component.evidence_matches) == 2
  end

  test "canonical component evidence links enforce resource and tenant ownership" do
    first_context = context()
    second_context = context()

    first_observation =
      observation(
        first_context,
        "1",
        %{"machine_id" => "machine-1"},
        %{},
        [],
        [%{"kind" => "cpu", "id" => "cpu-1"}]
      )

    second_observation =
      observation(
        second_context,
        "1",
        %{"machine_id" => "machine-2"},
        %{},
        [],
        [%{"kind" => "cpu", "id" => "cpu-2"}]
      )

    assert {:ok, first_resource, true} =
             Inventory.reconcile_observation(first_context.scope, first_observation.id)

    assert {:ok, second_resource, true} =
             Inventory.reconcile_observation(second_context.scope, second_observation.id)

    [first_component] = Catalog.list_actual_components(first_context.scope, first_resource.id)

    [foreign_evidence] =
      Inventory.list_component_evidence(second_context.scope, second_resource.id)

    ActualComponentEvidenceMatch
    |> Repo.get_by!(component_evidence_id: foreign_evidence.id)
    |> Repo.delete!()

    assert {:error, changeset} =
             %ActualComponentEvidenceMatch{
               organization_id: first_context.scope.organization_id,
               owner_resource_id: first_resource.id,
               actual_component_id: first_component.id,
               component_evidence_id: foreign_evidence.id
             }
             |> ActualComponentEvidenceMatch.changeset(%{match_strategy: "provider_id"})
             |> Repo.insert()

    assert %{component_evidence: [_]} = errors_on(changeset)

    assert_raise Ecto.NoResultsError, fn ->
      Catalog.get_actual_component!(second_context.scope, first_component.id)
    end
  end

  test "duplicate position and part identities in one snapshot do not merge components" do
    context = context()

    first =
      observation(
        context,
        "1",
        %{"machine_id" => "machine-1"},
        %{},
        [],
        [
          %{
            "kind" => "disk",
            "id" => "disk-a",
            "slot" => "BAY1",
            "part_number" => "PN1"
          },
          %{
            "kind" => "disk",
            "id" => "disk-b",
            "slot" => "BAY1",
            "part_number" => "PN1"
          }
        ]
      )

    assert {:ok, resource, true} = Inventory.reconcile_observation(context.scope, first.id)
    assert length(Catalog.list_actual_components(context.scope, resource.id)) == 2

    hardware_type =
      hardware_type_fixture(context.scope, "AMBIGUOUS-COMPONENTS", [
        %{kind: "disk", name: "Expected disk", position: "BAY1"}
      ])

    assert {:ok, _assignment} =
             Catalog.assign_hardware_type(context.scope, resource.id, hardware_type.id)

    {:ok, second_source} =
      Inventory.create_source(context.scope, %{kind: "bmc", name: "ambiguous-component-bmc"})

    second_context = %{context | source: second_source}

    ambiguous =
      observation(
        second_context,
        "2",
        %{"machine_id" => "machine-1"},
        %{},
        [],
        [
          %{
            "kind" => "disk",
            "id" => "bmc-disk",
            "slot" => "bay1",
            "part_number" => "pn1"
          }
        ]
      )

    assert {:ok, ^resource, false} =
             Inventory.reconcile_observation(context.scope, ambiguous.id)

    [ambiguous_evidence] =
      Inventory.list_component_evidence(context.scope, resource.id)
      |> Enum.filter(&(&1.observation_id == ambiguous.id))

    refute Repo.get_by(ActualComponentEvidenceMatch,
             component_evidence_id: ambiguous_evidence.id
           )

    assert length(Catalog.list_actual_components(context.scope, resource.id)) == 2

    assert context.scope
           |> Catalog.list_component_findings(resource.id)
           |> Enum.map(& &1.kind)
           |> Enum.sort() == ~w(ambiguous_component_identity ambiguous_expected_component)
  end

  test "retrying already-linked equal-time evidence does not overwrite canonical state" do
    context = context()
    observed_at = ~U[2026-08-01 12:00:00.000Z]

    first =
      observation_at(
        context,
        "1",
        observed_at,
        %{"machine_id" => "machine-1"},
        %{},
        [],
        [%{"kind" => "cpu", "id" => "cpu-1", "model" => "Model A"}]
      )

    second =
      observation_at(
        context,
        "2",
        observed_at,
        %{"machine_id" => "machine-1"},
        %{},
        [],
        [%{"kind" => "cpu", "id" => "cpu-1", "model" => "Model B"}]
      )

    assert {:ok, resource, true} = Inventory.reconcile_observation(context.scope, first.id)
    assert {:ok, ^resource, false} = Inventory.reconcile_observation(context.scope, second.id)
    assert [before_retry] = Catalog.list_actual_components(context.scope, resource.id)
    assert before_retry.model == "Model B"

    assert {:ok, ^resource, false} = Inventory.reconcile_observation(context.scope, first.id)

    assert [after_retry] = Catalog.list_actual_components(context.scope, resource.id)
    assert after_retry.model == "Model B"
    assert after_retry.updated_at == before_retry.updated_at
    assert length(after_retry.evidence_matches) == 2
  end

  test "component drift resolves while unexpected observed components remain open" do
    context = context()

    first =
      observation(
        context,
        "1",
        %{"machine_id" => "machine-1"},
        %{},
        [],
        [
          %{"kind" => "cpu", "id" => "cpu-1", "slot" => "CPU1", "model" => "Observed CPU"},
          %{"kind" => "disk", "id" => "disk-1", "slot" => "BAY9"}
        ]
      )

    assert {:ok, resource, true} = Inventory.reconcile_observation(context.scope, first.id)

    hardware_type =
      hardware_type_fixture(context.scope, "EXPECTED-COMPONENTS", [
        %{
          kind: "cpu",
          name: "CPU1",
          position: "CPU1",
          attributes: %{"model" => "Expected CPU"}
        }
      ])

    assert {:ok, _assignment} =
             Catalog.assign_hardware_type(context.scope, resource.id, hardware_type.id)

    drift =
      observation(
        context,
        "2",
        %{"machine_id" => "machine-1"},
        %{},
        [],
        [
          %{"kind" => "cpu", "id" => "cpu-1", "slot" => "CPU1", "model" => "Observed CPU"},
          %{"kind" => "disk", "id" => "disk-1", "slot" => "BAY9"}
        ]
      )

    assert {:ok, ^resource, false} = Inventory.reconcile_observation(context.scope, drift.id)

    assert [drift_finding, unexpected] =
             Catalog.list_component_findings(context.scope, resource.id)

    assert drift_finding.kind == "component_drift"
    assert drift_finding.details["differences"]["model"]["expected"] == "Expected CPU"
    assert unexpected.kind == "unexpected_actual_component"

    corrected =
      observation(
        context,
        "3",
        %{"machine_id" => "machine-1"},
        %{},
        [],
        [
          %{"kind" => "cpu", "id" => "cpu-1", "slot" => "CPU1", "model" => "Expected CPU"},
          %{"kind" => "disk", "id" => "disk-1", "slot" => "BAY9"}
        ]
      )

    assert {:ok, ^resource, false} = Inventory.reconcile_observation(context.scope, corrected.id)

    assert [%{kind: "unexpected_actual_component"}] =
             Catalog.list_component_findings(context.scope, resource.id)

    assert [%{kind: "component_drift", resolved_at: resolved_at}] =
             Catalog.list_component_findings(context.scope, resource.id, "resolved")

    assert resolved_at == corrected.observed_at
  end

  test "omitted observed specifications do not create component drift" do
    context = context()

    first =
      observation(
        context,
        "1",
        %{"machine_id" => "machine-1"},
        %{},
        [],
        [%{"kind" => "cpu", "id" => "cpu-1", "slot" => "CPU1"}]
      )

    assert {:ok, resource, true} = Inventory.reconcile_observation(context.scope, first.id)

    hardware_type =
      hardware_type_fixture(context.scope, "PARTIAL-COMPONENT-SPECS", [
        %{
          kind: "cpu",
          name: "CPU1",
          position: "CPU1",
          attributes: %{"model" => "Expected CPU"}
        }
      ])

    assert {:ok, _assignment} =
             Catalog.assign_hardware_type(context.scope, resource.id, hardware_type.id)

    partial =
      observation(
        context,
        "2",
        %{"machine_id" => "machine-1"},
        %{},
        [],
        [%{"kind" => "cpu", "id" => "cpu-1", "slot" => "CPU1"}]
      )

    assert {:ok, ^resource, false} = Inventory.reconcile_observation(context.scope, partial.id)
    assert Catalog.list_component_findings(context.scope, resource.id) == []
  end

  test "component findings retain stable identity when expectations rematerialize" do
    context = context()

    first =
      observation(
        context,
        "1",
        %{"machine_id" => "machine-1"},
        %{},
        [],
        [
          %{"kind" => "cpu", "id" => "cpu-1", "slot" => "CPU1", "model" => "Observed CPU"}
        ]
      )

    assert {:ok, resource, true} = Inventory.reconcile_observation(context.scope, first.id)

    hardware_type =
      hardware_type_fixture(context.scope, "STABLE-FINDING-IDENTITY", [
        %{
          kind: "cpu",
          name: "CPU1",
          position: "CPU1",
          attributes: %{"model" => "Expected CPU"}
        }
      ])

    assert {:ok, _assignment} =
             Catalog.assign_hardware_type(context.scope, resource.id, hardware_type.id)

    drift =
      observation(
        context,
        "2",
        %{"machine_id" => "machine-1"},
        %{},
        [],
        [
          %{"kind" => "cpu", "id" => "cpu-1", "slot" => "CPU1", "model" => "Observed CPU"}
        ]
      )

    assert {:ok, ^resource, false} = Inventory.reconcile_observation(context.scope, drift.id)
    assert [original] = Catalog.list_component_findings(context.scope, resource.id)

    [old_expected] = Catalog.list_expected_components(context.scope, resource.id)

    assert {:ok, _exception} =
             Catalog.put_expected_component_exception(context.scope, resource.id, %{
               action: "add",
               kind: "disk",
               name: "Local disk",
               changes: %{"position" => "BAY2"}
             })

    new_expected =
      context.scope
      |> Catalog.list_expected_components(resource.id)
      |> Enum.find(&(&1.kind == "cpu"))

    refute new_expected.id == old_expected.id

    repeated =
      observation(
        context,
        "3",
        %{"machine_id" => "machine-1"},
        %{},
        [],
        [
          %{"kind" => "cpu", "id" => "cpu-1", "slot" => "CPU1", "model" => "Observed CPU"}
        ]
      )

    assert {:ok, ^resource, false} = Inventory.reconcile_observation(context.scope, repeated.id)
    assert [current] = Catalog.list_component_findings(context.scope, resource.id)
    assert current.id == original.id
    assert current.resolution_key == original.resolution_key
    assert current.details["expected_component_id"] == new_expected.id
    assert Catalog.list_component_findings(context.scope, resource.id, "resolved") == []
  end

  test "older observations cannot change finding lifecycle and later drift can recur" do
    context = context()

    first =
      observation(
        context,
        "1",
        %{"machine_id" => "machine-1"},
        %{},
        [],
        [%{"kind" => "cpu", "id" => "cpu-1", "slot" => "CPU1", "model" => "Expected CPU"}]
      )

    assert {:ok, resource, true} = Inventory.reconcile_observation(context.scope, first.id)

    hardware_type =
      hardware_type_fixture(context.scope, "ORDERED-FINDINGS", [
        %{
          kind: "cpu",
          name: "CPU1",
          position: "CPU1",
          attributes: %{"model" => "Expected CPU"}
        }
      ])

    assert {:ok, _assignment} =
             Catalog.assign_hardware_type(context.scope, resource.id, hardware_type.id)

    newer_drift =
      observation(
        context,
        "3",
        %{"machine_id" => "machine-1"},
        %{},
        [],
        [%{"kind" => "cpu", "id" => "cpu-1", "slot" => "CPU1", "model" => "Drifted CPU"}]
      )

    assert {:ok, ^resource, false} =
             Inventory.reconcile_observation(context.scope, newer_drift.id)

    assert [opened] = Catalog.list_component_findings(context.scope, resource.id)
    assert opened.last_observed_at == newer_drift.observed_at

    assert {:error, invalid_state} =
             opened
             |> ComponentFinding.changeset(%{status: "resolved"})
             |> Repo.update()

    assert "must agree with finding status" in errors_on(invalid_state).resolved_at

    older_correction =
      observation(
        context,
        "2",
        %{"machine_id" => "machine-1"},
        %{},
        [],
        [%{"kind" => "cpu", "id" => "cpu-1", "slot" => "CPU1", "model" => "Expected CPU"}]
      )

    assert {:ok, ^resource, false} =
             Inventory.reconcile_observation(context.scope, older_correction.id)

    assert [still_open] = Catalog.list_component_findings(context.scope, resource.id)
    assert still_open.id == opened.id
    assert still_open.last_observed_at == newer_drift.observed_at

    correction =
      observation(
        context,
        "4",
        %{"machine_id" => "machine-1"},
        %{},
        [],
        [%{"kind" => "cpu", "id" => "cpu-1", "slot" => "CPU1", "model" => "Expected CPU"}]
      )

    assert {:ok, ^resource, false} = Inventory.reconcile_observation(context.scope, correction.id)
    assert Catalog.list_component_findings(context.scope, resource.id) == []

    assert [resolved] = Catalog.list_component_findings(context.scope, resource.id, "resolved")
    assert resolved.id == opened.id
    assert resolved.resolved_at == correction.observed_at

    assert {:ok, ^resource, false} =
             Inventory.reconcile_observation(context.scope, older_correction.id)

    assert Catalog.list_component_findings(context.scope, resource.id) == []

    recurrence =
      observation(
        context,
        "5",
        %{"machine_id" => "machine-1"},
        %{},
        [],
        [%{"kind" => "cpu", "id" => "cpu-1", "slot" => "CPU1", "model" => "Drifted again"}]
      )

    assert {:ok, ^resource, false} = Inventory.reconcile_observation(context.scope, recurrence.id)
    assert [reopened] = Catalog.list_component_findings(context.scope, resource.id)
    refute reopened.id == resolved.id
    assert reopened.resolution_key == resolved.resolution_key
    assert reopened.last_observed_at == recurrence.observed_at
  end

  test "non-authoritative component sections do not infer missing findings" do
    context = context()
    first = observation(context, "1", %{"machine_id" => "machine-1"})
    assert {:ok, resource, true} = Inventory.reconcile_observation(context.scope, first.id)

    hardware_type =
      hardware_type_fixture(context.scope, "NON-AUTHORITATIVE-COMPONENTS", [
        %{kind: "cpu", name: "CPU1", position: "CPU1", required: true}
      ])

    assert {:ok, _assignment} =
             Catalog.assign_hardware_type(context.scope, resource.id, hardware_type.id)

    for {id, components} <- [{"2", :absent}, {"3", nil}, {"4", []}] do
      partial = observation(context, id, %{"machine_id" => "machine-1"}, %{}, [], components)
      assert {:ok, ^resource, false} = Inventory.reconcile_observation(context.scope, partial.id)

      refute Enum.any?(
               Catalog.list_component_findings(context.scope, resource.id),
               &(&1.kind == "missing_expected_component")
             )
    end
  end

  test "component finding reads are scoped to the organization" do
    context = context()

    first =
      observation(
        context,
        "1",
        %{"machine_id" => "machine-1"},
        %{},
        [],
        [%{"kind" => "disk", "id" => "disk-1", "slot" => "BAY9"}]
      )

    assert {:ok, resource, true} = Inventory.reconcile_observation(context.scope, first.id)

    hardware_type = hardware_type_fixture(context.scope, "TENANT-FINDINGS", [])

    assert {:ok, _assignment} =
             Catalog.assign_hardware_type(context.scope, resource.id, hardware_type.id)

    repeated =
      observation(
        context,
        "2",
        %{"machine_id" => "machine-1"},
        %{},
        [],
        [%{"kind" => "disk", "id" => "disk-1", "slot" => "BAY9"}]
      )

    assert {:ok, ^resource, false} = Inventory.reconcile_observation(context.scope, repeated.id)

    assert [%{kind: "unexpected_actual_component"}] =
             Catalog.list_component_findings(context.scope, resource.id)

    foreign_context = context()
    assert Catalog.list_component_findings(foreign_context.scope, resource.id) == []
  end

  test "strong identity keeps a resource stable across hostname changes" do
    context = context()

    first =
      observation(context, "1", %{"hostname" => "compute-01", "machine_id" => "machine-1"}, %{
        "hostname" => "compute-01"
      })

    assert {:ok, resource, true} = Inventory.reconcile_observation(context.scope, first.id)

    second =
      observation(context, "2", %{"hostname" => "renamed-01", "machine_id" => "machine-1"}, %{
        "hostname" => "renamed-01"
      })

    assert {:ok, matched, false} = Inventory.reconcile_observation(context.scope, second.id)
    assert matched.id == resource.id
    assert Inventory.get_host_by_resource!(context.scope, resource.id).hostname == "renamed-01"
    assert Inventory.list_resources(context.scope) |> Enum.map(& &1.id) == [resource.id]

    machine_claims =
      context.scope
      |> Inventory.list_resource_identifier_claims(resource.id)
      |> Enum.filter(&(&1.kind == "machine_id"))

    assert length(machine_claims) == 2
    assert Enum.at(machine_claims, 0).first_seen_at == first.observed_at
    assert Enum.at(machine_claims, 1).first_seen_at == first.observed_at
    assert Enum.at(machine_claims, 1).last_seen_at == second.observed_at
  end

  test "uses a unique hostname only when no strong identity is reported" do
    context = context()
    first = observation(context, "1", %{"hostname" => "compute-01"})
    assert {:ok, resource, true} = Inventory.reconcile_observation(context.scope, first.id)

    second = observation(context, "2", %{"hostname" => "COMPUTE-01"})
    assert {:ok, matched, false} = Inventory.reconcile_observation(context.scope, second.id)
    assert matched.id == resource.id

    strong =
      observation(context, "3", %{"hostname" => "compute-01", "machine_id" => "new-machine"})

    assert {:ok, distinct, true} = Inventory.reconcile_observation(context.scope, strong.id)
    refute distinct.id == resource.id
  end

  test "rejects weak identity when hostname and FQDN resolve to different resources" do
    context = context()

    {:ok, hostname_resource} =
      Inventory.create_resource(context.scope, %{kind: "server", name: "hostname-resource"})

    {:ok, _host} =
      Inventory.create_host(context.scope, hostname_resource.id, %{hostname: "compute-01"})

    {:ok, fqdn_resource} =
      Inventory.create_resource(context.scope, %{kind: "server", name: "fqdn-resource"})

    {:ok, _host} =
      Inventory.create_host(context.scope, fqdn_resource.id, %{fqdn: "compute-01.example.com"})

    incoming =
      observation(context, "1", %{
        "hostname" => "compute-01",
        "fqdn" => "compute-01.example.com"
      })

    assert {:error, reconciliation} =
             Inventory.reconcile_observation(context.scope, incoming.id)

    assert reconciliation.errors["identity"] == "ambiguous"

    assert Enum.sort(reconciliation.errors["candidate_resource_ids"]) ==
             Enum.sort([hostname_resource.id, fqdn_resource.id])
  end

  test "does not weak-match a hostname retired by a strong-identity rename" do
    context = context()

    first =
      observation(context, "1", %{"hostname" => "old-name", "machine_id" => "machine-1"}, %{
        "hostname" => "old-name"
      })

    assert {:ok, original, true} = Inventory.reconcile_observation(context.scope, first.id)

    renamed =
      observation(context, "2", %{"hostname" => "new-name", "machine_id" => "machine-1"}, %{
        "hostname" => "new-name"
      })

    assert {:ok, ^original, false} = Inventory.reconcile_observation(context.scope, renamed.id)

    recycled = observation(context, "3", %{"hostname" => "old-name"}, %{"hostname" => "old-name"})
    assert {:ok, replacement, true} = Inventory.reconcile_observation(context.scope, recycled.id)
    refute replacement.id == original.id
  end

  test "fails safely when a strong identifier belongs to duplicate resources" do
    context = context()

    resources =
      for name <- ~w(compute-01 compute-02) do
        {:ok, resource} = Inventory.create_resource(context.scope, %{kind: "server", name: name})

        {:ok, _identifier} =
          Inventory.create_resource_identifier(context.scope, resource.id, %{
            kind: "serial_number",
            value: "duplicate-serial"
          })

        resource
      end

    observation = observation(context, "1", %{"serial_number" => "duplicate-serial"})

    assert {:error, reconciliation} =
             Inventory.reconcile_observation(context.scope, observation.id)

    assert reconciliation.status == "failed"
    assert reconciliation.errors["identity"] == "ambiguous"

    assert Enum.sort(reconciliation.errors["candidate_resource_ids"]) ==
             Enum.sort(Enum.map(resources, & &1.id))

    assert Repo.get_by!(ResourceIdentifierClaim, observation_id: observation.id).resource_id ==
             nil

    assert length(Inventory.list_resources(context.scope)) == 2
  end

  test "matches an exact MAC address set after stronger identifiers miss" do
    context = context()

    {:ok, resource} =
      Inventory.create_resource(context.scope, %{kind: "server", name: "compute-01"})

    for {name, mac} <- Enum.zip(~w(eth0 eth1), ~w(aa:bb:cc:dd:ee:01 aa:bb:cc:dd:ee:02)) do
      {:ok, _identifier} =
        Inventory.create_resource_identifier(context.scope, resource.id, %{
          kind: "mac_address",
          value: mac
        })

      {:ok, _interface} =
        Inventory.create_interface(context.scope, resource.id, %{name: name, mac_address: mac})
    end

    observation =
      observation(context, "1", %{
        "machine_id" => "previously-unseen",
        "mac_address" => ~w(aa-bb-cc-dd-ee-01 aa-bb-cc-dd-ee-02)
      })

    assert {:ok, matched, false} = Inventory.reconcile_observation(context.scope, observation.id)
    assert matched.id == resource.id
  end

  test "matches the current MAC set after an interface MAC replacement" do
    context = context()

    first =
      observation(
        context,
        "1",
        %{"machine_id" => "machine-1"},
        %{},
        [%{"name" => "eth0", "mac_address" => "aa:bb:cc:dd:ee:01"}]
      )

    assert {:ok, resource, true} = Inventory.reconcile_observation(context.scope, first.id)

    replacement =
      observation(
        context,
        "2",
        %{"machine_id" => "machine-1"},
        %{},
        [%{"name" => "eth0", "mac_address" => "aa:bb:cc:dd:ee:02"}]
      )

    assert {:ok, _resource, false} =
             Inventory.reconcile_observation(context.scope, replacement.id)

    {:ok, expected_mac} = Renga.Types.MacAddress.cast("aa:bb:cc:dd:ee:02")
    assert [%{mac_address: ^expected_mac}] = Inventory.list_interfaces(context.scope, resource.id)

    mac_only =
      observation(
        context,
        "3",
        %{"mac_address" => "aa:bb:cc:dd:ee:02"},
        %{},
        [%{"name" => "eth0", "mac_address" => "aa:bb:cc:dd:ee:02"}]
      )

    assert {:ok, matched, false} = Inventory.reconcile_observation(context.scope, mac_only.id)
    assert matched.id == resource.id
  end

  test "retains virtual interface MACs as network evidence without identity claims" do
    context = context()

    observation =
      observation(
        context,
        "1",
        %{
          "machine_id" => "machine-1",
          "mac_address" => ["aa:bb:cc:dd:ee:01", "02:42:ac:11:00:01"]
        },
        %{},
        [
          %{
            "name" => "eth0",
            "kind" => "ethernet",
            "mac_address" => "aa:bb:cc:dd:ee:01"
          },
          %{
            "name" => "docker0",
            "kind" => "virtual",
            "mac_address" => "02:42:ac:11:00:01"
          }
        ]
      )

    assert {:ok, resource, true} = Inventory.reconcile_observation(context.scope, observation.id)

    assert context.scope
           |> Inventory.list_resource_identifier_claims(resource.id)
           |> Enum.filter(&(&1.kind == "mac_address"))
           |> Enum.map(& &1.normalized_value) == ["aa:bb:cc:dd:ee:01"]

    assert resource.id
           |> then(&Inventory.list_interfaces(context.scope, &1))
           |> Enum.map(&{&1.name, &1.kind, &1.mac_address.address}) == [
             {"docker0", "virtual", {2, 66, 172, 17, 0, 1}},
             {"eth0", "ethernet", {170, 187, 204, 221, 238, 1}}
           ]

    physical_mac_only =
      observation(
        context,
        "2",
        %{"mac_address" => "aa:bb:cc:dd:ee:01"},
        %{},
        [
          %{
            "name" => "eth0",
            "kind" => "ethernet",
            "mac_address" => "aa:bb:cc:dd:ee:01"
          }
        ]
      )

    assert {:ok, matched_resource, false} =
             Inventory.reconcile_observation(context.scope, physical_mac_only.id)

    assert matched_resource.id == resource.id
  end

  test "retains bond and unknown MACs as evidence without claims or matching eligibility" do
    for {kind, sequence} <- Enum.with_index(~w(bond unknown), 1) do
      context = context()

      first =
        observation(
          context,
          Integer.to_string(sequence * 2 - 1),
          %{"machine_id" => "machine-#{kind}"},
          %{},
          [
            %{
              "name" => "eth0",
              "kind" => "ethernet",
              "mac_address" => "aa:bb:cc:dd:ee:01"
            },
            %{
              "name" => "#{kind}0",
              "kind" => kind,
              "mac_address" => "02:42:ac:11:00:01"
            }
          ]
        )

      assert {:ok, resource, true} = Inventory.reconcile_observation(context.scope, first.id)

      assert context.scope
             |> Inventory.list_resource_identifier_claims(resource.id)
             |> Enum.filter(&(&1.kind == "mac_address"))
             |> Enum.map(& &1.normalized_value) == ["aa:bb:cc:dd:ee:01"]

      assert resource.id
             |> then(&Inventory.list_interfaces(context.scope, &1))
             |> Enum.map(&{&1.name, &1.kind})
             |> Enum.sort() == Enum.sort([{kind <> "0", kind}, {"eth0", "ethernet"}])

      ethernet_mac_only =
        observation(
          context,
          Integer.to_string(sequence * 2),
          %{"mac_address" => "aa:bb:cc:dd:ee:01"},
          %{},
          [
            %{
              "name" => "eth0",
              "kind" => "ethernet",
              "mac_address" => "aa:bb:cc:dd:ee:01"
            }
          ]
        )

      assert {:ok, matched_resource, false} =
               Inventory.reconcile_observation(context.scope, ethernet_mac_only.id)

      assert matched_resource.id == resource.id
    end
  end

  test "matches only the present MAC set after an interface is omitted" do
    context = context()

    first =
      observation(
        context,
        "1",
        %{"machine_id" => "machine-1"},
        %{},
        [
          %{"name" => "eth0", "mac_address" => "aa:bb:cc:dd:ee:01"},
          %{"name" => "eth1", "mac_address" => "aa:bb:cc:dd:ee:02"}
        ]
      )

    assert {:ok, resource, true} = Inventory.reconcile_observation(context.scope, first.id)

    omitted =
      observation(
        context,
        "2",
        %{"machine_id" => "machine-1"},
        %{},
        [%{"name" => "eth0", "mac_address" => "aa:bb:cc:dd:ee:01"}]
      )

    assert {:ok, ^resource, false} = Inventory.reconcile_observation(context.scope, omitted.id)

    mac_only =
      observation(
        context,
        "3",
        %{"mac_address" => "aa:bb:cc:dd:ee:01"},
        %{},
        [%{"name" => "eth0", "mac_address" => "aa:bb:cc:dd:ee:01"}]
      )

    assert {:ok, matched, false} = Inventory.reconcile_observation(context.scope, mac_only.id)
    assert matched.id == resource.id
  end

  test "does not merge resources when different strong identifiers disagree" do
    context = context()

    {:ok, serial_resource} =
      Inventory.create_resource(context.scope, %{kind: "server", name: "serial"})

    {:ok, dmi_resource} = Inventory.create_resource(context.scope, %{kind: "server", name: "dmi"})

    {:ok, _identifier} =
      Inventory.create_resource_identifier(context.scope, serial_resource.id, %{
        kind: "serial_number",
        value: "serial-1"
      })

    {:ok, _identifier} =
      Inventory.create_resource_identifier(context.scope, dmi_resource.id, %{
        kind: "dmi_uuid",
        value: "dmi-1"
      })

    observation =
      observation(context, "1", %{"serial_number" => "serial-1", "dmi_uuid" => "dmi-1"})

    assert {:error, reconciliation} =
             Inventory.reconcile_observation(context.scope, observation.id)

    assert Enum.sort(reconciliation.errors["candidate_resource_ids"]) ==
             Enum.sort([serial_resource.id, dmi_resource.id])

    assert Inventory.list_resource_identifiers(context.scope, serial_resource.id)
           |> Enum.map(& &1.kind) == ["serial_number"]
  end

  test "retrying an observation records another attempt without duplicating claims" do
    context = context()

    observation =
      observation(context, "1", %{"hostname" => "compute-01", "machine_id" => "machine-1"})

    assert {:ok, resource, true} = Inventory.reconcile_observation(context.scope, observation.id)
    assert {:ok, matched, false} = Inventory.reconcile_observation(context.scope, observation.id)
    assert matched.id == resource.id

    assert Enum.map(
             Inventory.list_observation_reconciliations(context.scope, observation.id),
             & &1.attempt
           ) == [1, 2]

    assert length(Inventory.list_resource_identifier_claims(context.scope, resource.id)) == 2
  end

  test "a repaired ambiguous observation can link its existing claim on retry" do
    context = context()

    resources =
      for name <- ~w(compute-01 compute-02) do
        {:ok, resource} = Inventory.create_resource(context.scope, %{kind: "server", name: name})

        {:ok, _identifier} =
          Inventory.create_resource_identifier(context.scope, resource.id, %{
            kind: "serial_number",
            value: "duplicate-serial"
          })

        resource
      end

    observation = observation(context, "1", %{"serial_number" => "duplicate-serial"})
    assert {:error, _result} = Inventory.reconcile_observation(context.scope, observation.id)

    [_kept, removed] = resources
    Repo.delete!(removed)

    assert {:ok, matched, false} = Inventory.reconcile_observation(context.scope, observation.id)
    claim = Repo.get_by!(ResourceIdentifierClaim, observation_id: observation.id)
    assert claim.resource_id == matched.id
    assert claim.resource_identifier_id
  end

  test "older observations preserve history without regressing the current projection" do
    context = context()

    newer =
      observation(context, "2", %{"machine_id" => "machine-1"}, %{"hostname" => "current-name"})

    assert {:ok, resource, true} = Inventory.reconcile_observation(context.scope, newer.id)

    older =
      observation(context, "1", %{"machine_id" => "machine-1"}, %{"hostname" => "old-name"})

    assert {:ok, matched, false} = Inventory.reconcile_observation(context.scope, older.id)
    assert matched.id == resource.id
    assert Inventory.get_host_by_resource!(context.scope, resource.id).hostname == "current-name"

    claims = Inventory.list_resource_identifier_claims(context.scope, resource.id)
    assert Enum.all?(claims, &(&1.first_seen_at == older.observed_at))

    [result] = Inventory.list_observation_reconciliations(context.scope, older.id)
    refute result.metadata["freshness_advanced"]

    [condition] = Inventory.list_resource_conditions(context.scope, resource.id)
    assert condition.details["observation_id"] == newer.id
  end

  test "a delayed newest observation restores inventory after a later stale transition" do
    context = context()
    first = observation(context, "1", %{"machine_id" => "machine-1"})
    assert {:ok, resource, true} = Inventory.reconcile_observation(context.scope, first.id)

    [current_condition] = Inventory.list_resource_conditions(context.scope, resource.id)
    stale_at = DateTime.add(current_condition.last_transition_at, 1, :second)

    assert {:ok, %{status: "false"}} =
             Inventory.mark_resource_stale(context.scope, resource.id, stale_at)

    delayed = observation(context, "2", %{"machine_id" => "machine-1"})
    assert DateTime.compare(delayed.observed_at, stale_at) == :lt
    assert {:ok, _resource, false} = Inventory.reconcile_observation(context.scope, delayed.id)

    assert [%{status: "true", details: %{"observation_id" => observation_id}}] =
             Inventory.list_resource_conditions(context.scope, resource.id)

    assert observation_id == delayed.id
  end

  test "older snapshots do not reintroduce absent interfaces or addresses" do
    context = context()

    newer =
      observation(
        context,
        "2",
        %{"machine_id" => "machine-1"},
        %{},
        [
          %{
            "name" => "eth0",
            "addresses" => ["192.0.2.10/24"]
          }
        ]
      )

    assert {:ok, resource, true} = Inventory.reconcile_observation(context.scope, newer.id)

    older =
      observation(
        context,
        "1",
        %{"machine_id" => "machine-1"},
        %{},
        [
          %{"name" => "eth0", "addresses" => ["192.0.2.20/24"]},
          %{"name" => "eth1", "addresses" => ["198.51.100.10/24"]}
        ]
      )

    assert {:ok, _resource, false} = Inventory.reconcile_observation(context.scope, older.id)
    assert [%{name: "eth0"} = interface] = Inventory.list_interfaces(context.scope, resource.id)
    assert length(Inventory.list_addresses(context.scope, interface.id)) == 1
  end

  test "newer full snapshots mark omitted network rows as not present" do
    context = context()

    first =
      observation(
        context,
        "1",
        %{"machine_id" => "machine-1"},
        %{},
        [
          %{
            "name" => "eth0",
            "status" => "up",
            "addresses" => ["192.0.2.10/24", "192.0.2.20/24"]
          },
          %{"name" => "eth1", "status" => "up"}
        ]
      )

    assert {:ok, resource, true} = Inventory.reconcile_observation(context.scope, first.id)

    second =
      observation(
        context,
        "2",
        %{"machine_id" => "machine-1"},
        %{},
        [%{"name" => "eth0", "status" => "up", "addresses" => ["192.0.2.10/24"]}]
      )

    assert {:ok, _resource, false} = Inventory.reconcile_observation(context.scope, second.id)
    [eth0, eth1] = Inventory.list_interfaces(context.scope, resource.id)
    assert eth0.status == "up"
    assert eth1.status == "not_present"

    [current, omitted] = Inventory.list_addresses(context.scope, eth0.id)
    assert current.metadata["present"]
    refute omitted.metadata["present"]
  end

  test "absent interfaces preserve network state while an explicit empty collection withdraws it" do
    context = context()

    first =
      observation(context, "1", %{"machine_id" => "machine-1"}, %{}, [
        %{"name" => "eth0", "status" => "up", "addresses" => ["192.0.2.10/24"]}
      ])

    assert {:ok, resource, true} = Inventory.reconcile_observation(context.scope, first.id)

    partial = observation(context, "2", %{"machine_id" => "machine-1"}, %{}, :absent)
    assert {:ok, _resource, false} = Inventory.reconcile_observation(context.scope, partial.id)

    [interface] = Inventory.list_interfaces(context.scope, resource.id)
    assert interface.status == "up"

    assert [%{metadata: %{"present" => true}}] =
             Inventory.list_addresses(context.scope, interface.id)

    authoritative = observation(context, "3", %{"machine_id" => "machine-1"}, %{}, [])

    assert {:ok, _resource, false} =
             Inventory.reconcile_observation(context.scope, authoritative.id)

    [interface] = Inventory.list_interfaces(context.scope, resource.id)
    assert interface.status == "not_present"

    assert [%{metadata: %{"present" => false}}] =
             Inventory.list_addresses(context.scope, interface.id)
  end

  test "absent addresses preserve address state while an explicit empty collection withdraws it with an audit event" do
    context = context()

    first =
      observation(context, "1", %{"machine_id" => "machine-1"}, %{}, [
        %{"name" => "eth0", "status" => "up", "addresses" => ["192.0.2.10/24"]}
      ])

    assert {:ok, resource, true} = Inventory.reconcile_observation(context.scope, first.id)

    partial =
      observation(context, "2", %{"machine_id" => "machine-1"}, %{}, [
        %{"name" => "eth0", "status" => "up"}
      ])

    assert {:ok, _resource, false} = Inventory.reconcile_observation(context.scope, partial.id)
    [interface] = Inventory.list_interfaces(context.scope, resource.id)

    assert [%{metadata: %{"present" => true}}] =
             Inventory.list_addresses(context.scope, interface.id)

    authoritative =
      observation(context, "3", %{"machine_id" => "machine-1"}, %{}, [
        %{"name" => "eth0", "status" => "up", "addresses" => []}
      ])

    assert {:ok, _resource, false} =
             Inventory.reconcile_observation(context.scope, authoritative.id)

    assert [%{metadata: %{"present" => false}}] =
             Inventory.list_addresses(context.scope, interface.id)

    assert Enum.any?(
             Inventory.list_change_events(context.scope, resource.id),
             &(&1.kind == "updated" and &1.field == "addresses.192.0.2.10/24.present" and
                 &1.old_value == %{"value" => true} and &1.new_value == %{"value" => false})
           )
  end

  test "same-name discoveries receive collision-resistant resource names" do
    context = context()

    resources =
      for id <- ~w(1 2 3) do
        observation =
          observation(context, id, %{"hostname" => "compute-01", "machine_id" => "machine-#{id}"})

        assert {:ok, resource, true} =
                 Inventory.reconcile_observation(context.scope, observation.id)

        resource
      end

    assert resources |> Enum.map(& &1.name) |> Enum.uniq() |> length() == 3
  end

  test "upserts canonical interfaces and addresses while retaining each observation as evidence" do
    context = context()

    first =
      observation(
        context,
        "1",
        %{"machine_id" => "machine-1"},
        %{},
        [
          %{
            "name" => "eth0",
            "kind" => "ethernet",
            "status" => "down",
            "mac_address" => "aa:bb:cc:dd:ee:ff",
            "addresses" => ["192.0.2.10/24"]
          }
        ]
      )

    assert {:ok, resource, true} = Inventory.reconcile_observation(context.scope, first.id)
    [interface] = Inventory.list_interfaces(context.scope, resource.id)
    assert interface.status == "down"
    assert length(Inventory.list_addresses(context.scope, interface.id)) == 1

    second =
      observation(
        context,
        "2",
        %{"machine_id" => "machine-1"},
        %{},
        [
          %{
            "name" => "eth0",
            "kind" => "ethernet",
            "status" => "up",
            "mac_address" => "aa-bb-cc-dd-ee-ff",
            "addresses" => [
              %{"kind" => "ipv4", "address" => "192.0.2.10/24", "scope" => "global"},
              "2001:db8::10/64"
            ]
          }
        ]
      )

    assert {:ok, matched, false} = Inventory.reconcile_observation(context.scope, second.id)
    assert matched.id == resource.id

    [interface] = Inventory.list_interfaces(context.scope, resource.id)
    assert interface.status == "up"
    addresses = Inventory.list_addresses(context.scope, interface.id)
    assert length(addresses) == 2

    assert Enum.find(
             addresses,
             &match?(%Postgrex.INET{address: {192, 0, 2, 10}}, &1.address)
           ).scope == "global"

    assert Repo.aggregate(InterfaceEvidence, :count) == 2
    assert Repo.aggregate(AddressEvidence, :count) == 3

    assert Enum.any?(
             Inventory.list_change_events(context.scope, resource.id),
             &(&1.kind == "updated" and &1.field == "interfaces.eth0.status")
           )
  end

  test "explicit host masks remain idempotent after Postgrex decodes them as nil" do
    context = context()

    interface = %{
      "name" => "lo",
      "kind" => "loopback",
      "status" => "up",
      "addresses" => ["127.0.0.1/32", "::1/128"]
    }

    first = observation(context, "1", %{"machine_id" => "machine-1"}, %{}, [interface])
    assert {:ok, resource, true} = Inventory.reconcile_observation(context.scope, first.id)

    second = observation(context, "2", %{"machine_id" => "machine-1"}, %{}, [interface])
    assert {:ok, ^resource, false} = Inventory.reconcile_observation(context.scope, second.id)

    [canonical_interface] = Inventory.list_interfaces(context.scope, resource.id)
    assert length(Inventory.list_addresses(context.scope, canonical_interface.id)) == 2
    assert Repo.aggregate(AddressEvidence, :count) == 4
  end

  test "partial interface reports preserve omitted canonical attributes and ownership" do
    context = context()

    first =
      observation(
        context,
        "1",
        %{"machine_id" => "machine-1"},
        %{},
        [%{"name" => "br0", "kind" => "bridge", "status" => "up", "addresses" => []}]
      )

    assert {:ok, resource, true} = Inventory.reconcile_observation(context.scope, first.id)
    [original] = Inventory.list_interfaces(context.scope, resource.id)

    second =
      observation(
        context,
        "2",
        %{"machine_id" => "machine-1"},
        %{},
        [%{"name" => "br0", "addresses" => ["192.0.2.10/24"]}]
      )

    assert {:ok, ^resource, false} = Inventory.reconcile_observation(context.scope, second.id)
    [interface] = Inventory.list_interfaces(context.scope, resource.id)

    assert interface.kind == "bridge"
    assert interface.status == "up"

    for field <- ~w(kind status) do
      assert interface.metadata["field_owners"][field] ==
               original.metadata["field_owners"][field]
    end
  end

  test "field precedence is deterministic and source disagreements remain visible" do
    context = context()

    first =
      observation(
        context,
        "1",
        %{"machine_id" => "machine-1"},
        %{"hostname" => "agent-name", "vendor" => "Agent Vendor"}
      )

    assert {:ok, resource, true} = Inventory.reconcile_observation(context.scope, first.id)

    {:ok, bmc_source} =
      Inventory.create_source(context.scope, %{kind: "bmc", name: "bmc-collector"})

    bmc_context = %{context | source: bmc_source}

    second =
      observation(
        bmc_context,
        "2",
        %{"machine_id" => "machine-1"},
        %{"hostname" => "bmc-name", "vendor" => "BMC Vendor"}
      )

    assert {:ok, matched, false} = Inventory.reconcile_observation(context.scope, second.id)
    assert matched.id == resource.id

    host = Inventory.get_host_by_resource!(context.scope, resource.id)
    assert host.hostname == "agent-name"
    assert host.vendor == "BMC Vendor"
    assert host.metadata["field_owners"]["hostname"]["source_id"] == context.source.id
    assert host.metadata["field_owners"]["vendor"]["source_id"] == bmc_source.id

    conflict_fields =
      context.scope
      |> Inventory.list_change_events(resource.id)
      |> Enum.filter(&(&1.kind == "conflict"))
      |> Enum.map(& &1.field)

    assert "host.hostname" in conflict_fields
    assert "host.vendor" in conflict_fields
  end

  test "manual and desired values are not overwritten and conflicts are audited" do
    context = context()

    {:ok, resource} =
      Inventory.create_resource(context.scope, %{
        kind: "server",
        name: "compute-01",
        spec: %{"host" => %{"model" => "Desired Model"}}
      })

    {:ok, _identifier} =
      Inventory.create_resource_identifier(context.scope, resource.id, %{
        kind: "machine_id",
        value: "machine-1"
      })

    {:ok, _override} =
      Inventory.create_resource_override(context.scope, resource.id, %{
        field: "host.vendor",
        value: %{"value" => "Manual Vendor"},
        reason: "Verified by operator"
      })

    observation =
      observation(
        context,
        "1",
        %{"machine_id" => "machine-1"},
        %{"vendor" => "Observed Vendor", "model" => "Observed Model"}
      )

    assert {:ok, matched, false} = Inventory.reconcile_observation(context.scope, observation.id)
    host = Inventory.get_host_by_resource!(context.scope, matched.id)
    assert host.vendor == "Manual Vendor"
    assert host.model == "Observed Model"
    assert Inventory.get_resource!(context.scope, matched.id).spec == resource.spec

    conflicts =
      context.scope
      |> Inventory.list_change_events(resource.id)
      |> Enum.filter(&(&1.kind == "conflict"))

    assert Enum.any?(
             conflicts,
             &(&1.field == "host.vendor" and &1.metadata["reason"] == "manual_override")
           )

    assert Enum.any?(
             conflicts,
             &(&1.field == "host.model" and &1.metadata["reason"] == "desired_state")
           )
  end

  test "accepted overrides immediately materialize with operator provenance and remain authoritative" do
    context = context()

    {:ok, user} =
      Accounts.register_user(%{email: "override#{System.unique_integer()}@example.com"})

    scope = %{context.scope | user: user}

    observation =
      observation(context, "1", %{"machine_id" => "override-machine"}, %{"vendor" => "Observed"})

    assert {:ok, resource, true} = Inventory.reconcile_observation(scope, observation.id)

    assert {:ok, override} =
             Inventory.create_resource_override(scope, resource.id, %{
               field: "host.vendor",
               value: %{"value" => "Operator Vendor"}
             })

    assert {:ok, omitted_override} =
             Inventory.create_resource_override(scope, resource.id, %{
               field: "host.asset_tag",
               value: %{"value" => "ASSET-42"}
             })

    host = Inventory.get_host_by_resource!(scope, resource.id)
    assert host.vendor == "Operator Vendor"
    assert host.asset_tag == "ASSET-42"

    for {field, accepted_override} <- [
          {"vendor", override},
          {"asset_tag", omitted_override}
        ] do
      owner = host.metadata["field_owners"][field]
      assert owner["source_kind"] == "manual"
      assert owner["override_id"] == accepted_override.id
      assert owner["created_by_user_id"] == user.id
      assert owner["overridden_at"] == DateTime.to_iso8601(accepted_override.inserted_at)
      refute Map.has_key?(owner, "observation_id")
    end

    events = Inventory.list_change_events(scope, resource.id)

    assert Enum.any?(events, fn event ->
             event.kind == "manual_override" and event.field == "host.vendor" and
               event.metadata["override_id"] == override.id and
               event.metadata["created_by_user_id"] == user.id and
               is_nil(event.observation_id) and is_nil(event.source_id)
           end)

    later =
      observation(context, "2", %{"machine_id" => "override-machine"}, %{
        "vendor" => "Later Observation",
        "asset_tag" => "LATER"
      })

    assert {:ok, ^resource, false} = Inventory.reconcile_observation(scope, later.id)
    host = Inventory.get_host_by_resource!(scope, resource.id)
    assert host.vendor == "Operator Vendor"
    assert host.asset_tag == "ASSET-42"
    assert host.metadata["field_owners"]["vendor"]["override_id"] == override.id
  end

  test "overriding an existing MAC records JSON-safe old and new audit values" do
    context = context()

    observation =
      observation(
        context,
        "1",
        %{"machine_id" => "mac-override-machine"},
        %{},
        [%{"name" => " eth0 ", "mac_address" => "00:11:22:33:44:55"}]
      )

    assert {:ok, resource, true} = Inventory.reconcile_observation(context.scope, observation.id)

    assert {:ok, override} =
             Inventory.create_resource_override(context.scope, resource.id, %{
               field: "interfaces. eth0 .mac_address",
               value: %{"value" => "aa:bb:cc:dd:ee:ff"}
             })

    assert override.field == "interfaces.eth0.mac_address"

    assert event =
             Enum.find(Inventory.list_change_events(context.scope, resource.id), fn event ->
               event.kind == "manual_override" and event.field == "interfaces.eth0.mac_address"
             end)

    assert event.old_value == %{"value" => "00:11:22:33:44:55"}
    assert event.new_value == %{"value" => "aa:bb:cc:dd:ee:ff"}
  end

  test "normalizes canonical names before lookup, comparison, and retry" do
    context = context()

    observation =
      observation(
        context,
        "1",
        %{"machine_id" => "machine-1"},
        %{"hostname" => " Compute-01 "},
        [%{"name" => " eth0 ", "kind" => "ethernet", "status" => "up"}]
      )

    assert {:ok, resource, true} = Inventory.reconcile_observation(context.scope, observation.id)

    assert {:ok, _resource, false} =
             Inventory.reconcile_observation(context.scope, observation.id)

    assert Inventory.get_host_by_resource!(context.scope, resource.id).hostname == "compute-01"
    assert [%{name: "eth0"}] = Inventory.list_interfaces(context.scope, resource.id)

    refute Enum.any?(
             Inventory.list_change_events(context.scope, resource.id),
             &(&1.kind == "updated" and &1.field == "host.hostname")
           )
  end

  test "applies interface overrides and desired conflicts on first discovery" do
    context = context()

    {:ok, resource} =
      Inventory.create_resource(context.scope, %{
        kind: "server",
        name: "compute-01",
        spec: %{"interfaces" => %{"eth0" => %{"kind" => "bridge"}}}
      })

    {:ok, _identifier} =
      Inventory.create_resource_identifier(context.scope, resource.id, %{
        kind: "machine_id",
        value: "machine-1"
      })

    {:ok, _override} =
      Inventory.create_resource_override(context.scope, resource.id, %{
        field: "interfaces.eth0.status",
        value: %{"value" => "down"}
      })

    observation =
      observation(
        context,
        "1",
        %{"machine_id" => "machine-1"},
        %{},
        [%{"name" => "eth0", "kind" => "ethernet", "status" => "up"}]
      )

    assert {:ok, _resource, false} =
             Inventory.reconcile_observation(context.scope, observation.id)

    assert [%{status: "down", kind: "ethernet", metadata: %{"field_owners" => owners}}] =
             Inventory.list_interfaces(context.scope, resource.id)

    assert owners["status"]["source_kind"] == "manual"

    conflicts = Inventory.list_change_events(context.scope, resource.id)

    assert Enum.any?(
             conflicts,
             &(&1.field == "interfaces.eth0.status" and
                 &1.metadata["reason"] == "manual_override")
           )

    assert Enum.any?(
             conflicts,
             &(&1.field == "interfaces.eth0.kind" and
                 &1.metadata["reason"] == "desired_state")
           )
  end

  test "equal-time facts use observation identity as a deterministic tie breaker" do
    context = context()
    observed_at = ~U[2026-08-01 12:00:00.000Z]

    first =
      observation_at(
        context,
        "1",
        observed_at,
        %{"machine_id" => "machine-1"},
        %{"vendor" => "First"},
        []
      )

    second =
      observation_at(
        context,
        "2",
        observed_at,
        %{"machine_id" => "machine-1"},
        %{"vendor" => "Second"},
        []
      )

    [{winner, winner_value}, {loser, _loser_value}] =
      [{first, "First"}, {second, "Second"}]
      |> Enum.sort_by(fn {observation, _value} -> observation.id end, :desc)

    assert {:ok, resource, true} = Inventory.reconcile_observation(context.scope, winner.id)
    assert {:ok, _resource, false} = Inventory.reconcile_observation(context.scope, loser.id)
    assert Inventory.get_host_by_resource!(context.scope, resource.id).vendor == winner_value

    [loser_result] = Inventory.list_observation_reconciliations(context.scope, loser.id)
    refute loser_result.metadata["freshness_advanced"]

    [condition] = Inventory.list_resource_conditions(context.scope, resource.id)
    assert condition.details["observation_id"] == winner.id
  end

  test "accepts nullable host name attributes during reconciliation" do
    context = context()

    observation =
      observation(
        context,
        "1",
        %{"machine_id" => "machine-1"},
        %{"hostname" => nil, "fqdn" => nil}
      )

    assert {:ok, resource, true} = Inventory.reconcile_observation(context.scope, observation.id)

    assert %{hostname: nil, fqdn: nil} =
             Inventory.get_host_by_resource!(context.scope, resource.id)
  end

  test "records and deduplicates each conflict reason for the same field" do
    context = context()

    {:ok, resource} =
      Inventory.create_resource(context.scope, %{
        kind: "server",
        name: "compute-01",
        spec: %{"host" => %{"vendor" => "Desired"}}
      })

    {:ok, _identifier} =
      Inventory.create_resource_identifier(context.scope, resource.id, %{
        kind: "machine_id",
        value: "machine-1"
      })

    {:ok, _override} =
      Inventory.create_resource_override(context.scope, resource.id, %{
        field: "host.vendor",
        value: %{"value" => "Manual"}
      })

    observation =
      observation(context, "1", %{"machine_id" => "machine-1"}, %{"vendor" => "Observed"})

    assert {:ok, _resource, false} =
             Inventory.reconcile_observation(context.scope, observation.id)

    assert {:ok, _resource, false} =
             Inventory.reconcile_observation(context.scope, observation.id)

    reasons =
      context.scope
      |> Inventory.list_change_events(resource.id)
      |> Enum.filter(&(&1.kind == "conflict" and &1.field == "host.vendor"))
      |> Enum.map(& &1.metadata["reason"])
      |> Enum.sort()

    assert reasons == ["desired_state", "manual_override"]
  end

  test "a rejected older claim does not mutate accepted claim history" do
    context = context()
    newer = observation(context, "2", %{"machine_id" => "machine-1"})
    older = observation(context, "1", %{"machine_id" => "machine-1"})

    assert {:ok, claim} =
             Inventory.create_resource_identifier_claim(
               context.scope,
               context.source.id,
               newer.id,
               %{kind: "machine_id", value: "machine-1"}
             )

    assert {:error, _changeset} =
             Inventory.create_resource_identifier_claim(
               context.scope,
               context.source.id,
               older.id,
               %{kind: "machine_id", value: "machine-1", confidence: -1}
             )

    assert Repo.reload!(claim).first_seen_at == newer.observed_at
  end

  test "unexpected projection failures are retained as terminal reconciliation attempts" do
    context = context()

    observation =
      observation(
        context,
        "1",
        %{"machine_id" => "machine-1"},
        %{"vendor" => %{"invalid" => true}}
      )

    assert {:error, result} = Inventory.reconcile_observation(context.scope, observation.id)
    assert result.status == "failed"
    assert result.errors["processing"]

    assert [%{status: "failed"}] =
             Inventory.list_observation_reconciliations(context.scope, observation.id)
  end

  test "ingestion retains a terminal result when projection rolls back" do
    context = context()

    observation =
      observation(
        context,
        "1",
        %{"machine_id" => "machine-1"},
        %{"vendor" => %{"invalid" => true}}
      )

    assert {:error, %{status: "failed", errors: %{"processing" => "projection_failed"}}} =
             Inventory.reconcile_observation_once(context.scope, observation.id)

    assert [%{status: "failed", attempt: 1}] =
             Inventory.list_observation_reconciliations(context.scope, observation.id)
  end

  defp hardware_type_fixture(scope, model, templates) do
    slug = model |> String.downcase() |> String.replace(~r/[^a-z0-9]+/, "-")

    {:ok, manufacturer} =
      Catalog.create_manufacturer(
        scope,
        %{name: "Finding vendor #{model}", lifecycle_state: "active"},
        %{slug: "finding-vendor-#{slug}"}
      )

    {:ok, hardware_type} =
      Catalog.create_hardware_type(
        scope,
        %{name: "Finding hardware #{model}", lifecycle_state: "active"},
        %{manufacturer_id: manufacturer.id, model: model, device_class: "server"}
      )

    {:ok, _revision} =
      Catalog.create_hardware_type_revision(scope, hardware_type, %{}, templates)

    hardware_type
  end
end
